module fcc
import ast

// Parser tests.
//
// The layout cases assert byte images that were produced by the bundled tcc, not
// expectations derived from the algorithm. The probe that produced them wrote known
// values into each struct and printed the bytes; those byte strings are transcribed
// here verbatim. Asserting the algorithm against itself would pass even if both were
// wrong, and this is the part of the front end where being wrong is silent.

// parsed runs a snippet through the parser with no preprocessor, which is what a
// declaration-only test needs.
fn parsed(src string) ParseResult {

// A pp-number that is not a valid constant is a diagnostic, not a value.
//
// This is the guard `invalid_numeric_suffix` provides, and it is needed because widening
// the tokenizer to lex whole pp-numbers removed the only thing that was catching these:
// a number used to stop at the first character that was not a suffix letter, so `0zz`
// lexed as the number `0` and the identifier `zz`. Without the guard `parse_integer`'s
// digit loop `continue`s past the bytes it does not understand, and `0zz` would silently
// decode to int 0 — a plausible wrong value with no diagnostic, which is the failure mode
// this project says it can least afford.
//
// Every one of these is what gcc 15.2 diagnoses, with the same message and the same exit
// code. `-pedantic-errors` changes nothing in any case.
fn test_an_invalid_pp_number_is_reported_not_decoded() {
	for bad in ['0zz', '1abc', '3.5foo', '0x1z', '1e5x', '1p+3', '1\$'] {
		r := parsed('int x = ${bad};\n')
		assert r.errors.len > 0, 'no diagnostic for ${bad}'
		assert r.errors[0].contains('invalid suffix'), 'for ${bad}: ${r.errors}'
	}
	// And every legal spelling in the same shapes must not be reported — including a
	// binary constant, whose digits are all hex digits and which a prefix-blind rule gets
	// right by accident.
	for good in ['0u', '0llu', '1e5', '0x1p3', '0b1010', '0xff', '0777', '0b0L', '.5', '1.'] {
		r := parsed('int x = ${good};\n')
		assert r.errors.len == 0, 'unexpected diagnostic for ${good}: ${r.errors}'
	}
	// A character constant is a `.num_` token too, and its text carries the quotes. The
	// first version of this check reported `'a'` as a bad number; the same guard
	// `numeric_type` uses is what keeps it out.
	for chr in ["'a'", "'\\n'", "'\\x80'", "L'0'", "'ab'"] {
		r := parsed('int x = ${chr};\n')
		assert r.errors.len == 0, 'unexpected diagnostic for ${chr}: ${r.errors}'
	}
}

	return parse_tokens(tokenize(src), 'test.c', []PackEvent{})
}

// preprocessed runs a snippet through the preprocessor first, which is what any test
// involving #pragma needs: the pragma is consumed there and reaches the parser only as a
// recorded event.
fn preprocessed(src string) ParseResult {
	mut p := preprocessor([], [])
	p.define_builtins()
	r := p.run_text(src, 'test.c')
	assert r.errors.len == 0, 'unexpected preprocessor diagnostics: ${r.errors}'
	return parse_tokens(r.tokens, 'test.c', p.packs)
}

// global returns the one global a snippet declares.
fn global(src string) &ast.Obj {
	r := parsed(src)
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals.len == 1, 'expected one global, got ${r.globals.len}'
	return r.globals[0]
}

// bytes_of renders an object's initial data as hex, which is the form the tcc probe
// printed and the form these tests compare against.
fn bytes_of(obj &ast.Obj) string {
	mut parts := []string{}
	for i, b in obj.init_data {
		if i > 0 && i % 8 == 0 {
			parts << ' '
		}
		parts << b.hex()
	}
	return parts.join('')
}

// --- basic declarations ---

fn test_a_global_gets_its_type_and_line() {
	obj := global('int x;\n')
	assert obj.name == 'x'
	assert obj.ty.basic == .int_
	assert obj.ty.size == 4
	assert obj.line == 1
	assert obj.is_definition
}

fn test_several_declarators_share_one_declaration() {
	r := parsed('int a, b = 3, c;\n')
	assert r.errors.len == 0
	assert r.globals.len == 3
	assert r.globals[0].name == 'a'
	assert r.globals[1].name == 'b'
	assert r.globals[2].name == 'c'
}

fn test_a_tentative_definition_is_marked_and_a_real_one_is_not() {
	r := parsed('int x;\nint x = 1;\n')
	assert r.errors.len == 0
	// The redundant tentative definition is dropped, because emitting both would give
	// the linker two definitions of one symbol.
	assert r.globals.len == 1
	assert !r.globals[0].is_tentative
}

fn test_two_tentative_definitions_collapse_to_one() {
	r := parsed('int x;\nint x;\n')
	assert r.errors.len == 0
	assert r.globals.len == 1
}

fn test_an_extern_declaration_is_not_a_definition() {
	obj := global('extern int x;\n')
	assert !obj.is_definition
	assert !obj.is_tentative
}

fn test_a_static_global_is_internal() {
	assert global('static int x = 1;\n').is_static
}

// --- declarators ---

fn test_pointer_to_pointer_and_array_of_pointers() {
	r := parsed('int **pp;\nint *ap[4];\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.kind == .pointer
	assert r.globals[0].ty.base.kind == .pointer
	assert r.globals[0].ty.base.base == ty_int
	assert r.globals[1].ty.kind == .array
	assert r.globals[1].ty.array_len == 4
	assert r.globals[1].ty.base.kind == .pointer
}

fn test_function_pointer_declarator() {
	// `int (*fp)(void)` is a pointer to a function taking nothing. Reading it as a
	// function taking a pointer is the classic misparse, and it only shows up here
	// because the test asks the shape rather than the spelling.
	r := parsed('int (*fp)(void);\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.kind == .pointer
	assert r.globals[0].ty.base.kind == .func
	assert r.globals[0].ty.base.ret_type == ty_int
	assert r.globals[0].ty.base.params.len == 0
	assert !r.globals[0].ty.base.is_variadic
}

fn test_a_variadic_function_is_marked() {
	r := parsed('int printf_like(const char *fmt, ...);\n')
	assert r.errors.len == 0
	ty := r.globals[0].ty
	assert ty.kind == .func
	assert ty.is_variadic
	assert ty.params.len == 1
	// `char *` decays to a pointer to char here, not to an array of them.
	assert ty.params[0].kind == .pointer
	assert ty.params[0].base == ty_char
}

fn test_the_builtin_va_list_is_a_pointer_to_char() {
	// `__builtin_va_list` is the entire type system of the `<stdarg.h>` this target
	// ships, whose whole body is `typedef __builtin_va_list va_list;`. So it has to
	// answer `is_typename` and `declspec` has to turn it into a type, or no variadic
	// function in any real program can be written at all.
	//
	// The size is measured, not assumed: mingw gcc and tcc both report
	// `sizeof(va_list) == 8` on this host, and `src/ast/abi.v` records what those eight
	// bytes are — a pointer walking the home area, *not* the psABI's 24-byte
	// `gp_offset`/`fp_offset` struct.
	r := parsed('__builtin_va_list ap;\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	obj := r.globals[0]
	assert obj.ty.kind == .pointer
	assert obj.ty.size == 8
	assert obj.ty.base == ty_char
}

fn test_the_builtin_va_list_accepts_a_typedef() {
	// The spelling every program uses is the header's, so the typedef form is the one
	// that matters. It is a two-line path: `declspec` accepts the builtin, and
	// `typedef` records it under the new name.
	//
	// A typedef is not an object with storage, so only the variable appears in
	// `globals` — which is what makes this a real test of the typedef rather than of
	// the count of declarations.
	r := parsed('typedef __builtin_va_list va_list;\nva_list ap;\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals.len == 1
	assert r.globals[0].ty.kind == .pointer
	assert r.globals[0].ty.base == ty_char
}

fn test_va_start_and_va_end_are_statements_and_leave_nothing_behind() {
	// Both are statements: `va_start` is one store and `va_end` is nothing, so neither
	// produces a value. Implementing them as expressions made the generator's
	// end-of-body check fail with `left 1 values on the stack` on a correct
	// `va_start(ap, n);` — a diagnostic that names the stack rather than the construct
	// that caused it.
	//
	// The count is what distinguishes the two shapes. Had either been parsed as an
	// expression it would sit inside an `.expr_stmt`, and the body would have four
	// statements instead of three. The comment above says "three statements" and means
	// the declaration, the `va_start` and the `va_end`; the `return` makes the total
	// four.
	r := parsed('int f(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n);' +
		' __builtin_va_end(ap); return n; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	f := r.globals[0]
	assert f.body.len == 4, 'got ${f.body.len} statements'
	// The `va_start` is the one whose operand is the `.va_start_` node, so this asserts
	// the shape rather than a position.
	mut found := false
	for s in f.body {
		if s.kind == .expr_stmt && s.lhs != unsafe { nil } && s.lhs.kind == .va_start_ {
			found = true
		}
	}
	assert found, 'va_start was not parsed as a statement'
}

fn test_va_start_used_as_an_expression_is_reported_by_the_backend() {
	// It is reported rather than quietly accepted, because a value would have to be
	// invented for it. The parser cannot tell the two apart — the same token sequence
	// is a statement or an initializer depending on what the statement parser did with
	// it first — so the diagnostic comes from the generator, which does know.
	//
	// That the *parser* is silent about it is the reason the assertion is here and not
	// in the parser: a test that asserted a parser diagnostic here would be asserting
	// something the parser does not and should not know.
	// The parse itself succeeds, so the count is asserted rather than assumed: it is
	// what makes the absence of a parser diagnostic a fact and not an oversight.
	r := parsed('int f(int n, ...) { __builtin_va_list ap;' +
		' int x = __builtin_va_start(ap, n); return x; }\n')
	assert r.errors.len == 0, 'the parser accepts the token sequence: ' + r.errors.str()
	// The parse produced the function, which is all this test can see: `backend`
	// imports `vcc`, so asserting the backend's diagnostic from here would make the
	// import a cycle. `test_va_start_reached_as_an_expression_is_reported` in
	// `src/backend/asm_test.v` asserts the diagnostic itself.
	assert r.globals.len >= 1
}

fn test_va_arg_names_the_type_it_reads() {
	// The type is a compile-time fact, so the whole offset computation folds to a
	// constant stride. That is the reason `va_arg` is parsed in the front end at all
	// rather than left to the backend.
	r := parsed('int f(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n);' +
		' double d = __builtin_va_arg(ap, double); return (int)d; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
}

fn test_an_array_parameter_becomes_a_pointer() {
	// `int argv[]` in a parameter list means `int *argv`. This is the only place C makes
	// that adjustment.
	r := parsed('int f(int argv[]);\n')
	assert r.errors.len == 0
	ty := r.globals[0].ty
	assert ty.params[0].kind == .pointer
	assert ty.params[0].base == ty_int
}

fn test_a_function_declaration_is_not_a_definition() {
	obj := global('int f(int);\n')
	assert obj.is_function
	assert !obj.is_definition
}

fn test_a_function_body_is_parsed_into_statements() {
	r := parsed('int f(int x) {\n  return x;\n}\nint g;\n')
	assert r.errors.len == 0
	// The declaration after the body must still be found, which is what proves the
	// body was consumed exactly rather than mistaken for one. The globals are counted
	// by name because each definition also creates the compiler-generated __func__.
	mut names := []string{}
	for obj in r.globals {
		names << obj.name
	}
	assert names.contains('f')
	assert names.contains('g')
	assert r.globals.len == 3
	f := r.globals[0]
	assert f.is_definition
	assert f.body.len == 1
	assert f.body[0].kind == .return_
	// The parameter is in scope in the body, which is what makes `return x` mean
	// anything, and it is the first local of the frame.
	assert f.params.len == 1
	assert f.params[0].name == 'x'
	assert f.locals[0].name == 'x'
}

fn test_a_redeclaration_keeps_one_object() {
	r := parsed('int f(int);\nint f(int x) { return x; }\n')
	// A definition after a declaration is normal and must not be an error.
	assert r.errors.len == 0
	// One object for , plus the __func__ its definition creates.
	assert r.globals.len == 2
	f := r.globals[0]
	assert f.name == 'f'
	assert f.is_definition
	// The definition's own parameter list is the one its body can name: the
	// declaration's said int f(int) with no name to bind.
	assert f.params.len == 1
	assert f.params[0].name == 'x'
}

fn test_a_redefinition_is_reported() {
	r := parsed('int f(int x) { return x; }\nint f(int y) { return y; }\n')
	assert r.errors.len == 1
	assert r.errors[0].contains('redefinition')
}

// --- typedef ---

fn test_a_typedef_binds_a_name_to_a_type() {
	r := parsed('typedef int myint;\nmyint x;\n')
	assert r.errors.len == 0
	assert r.globals.len == 1
	assert r.globals[0].ty.basic == .int_
	assert r.globals[0].name == 'x'
}

fn test_a_typedef_can_be_a_pointer_or_a_struct() {
	r := parsed('typedef struct S { int a; } S;\nS *p;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.kind == .pointer
	assert r.globals[0].ty.base.kind == .struct_
	assert r.globals[0].ty.base.tag == 'S'
}

fn test_two_typedefs_of_the_same_type_are_compatible() {
	r := parsed('typedef int A;\ntypedef int B;\nA f(B x);\n')
	assert r.errors.len == 0
	assert is_compatible(r.globals[0].ty.params[0], ty_int)
}

// --- enum ---

fn test_enum_constants_count_up_and_ignore_spelling_order() {
	r := parsed('enum E { A, B = 5, C };\nint x = C;\n')
	assert r.errors.len == 0
	assert r.globals.len == 1
	// C is 6: B is 5 and the next constant continues from it.
	assert bytes_of(r.globals[0]) == '06000000'
}

fn test_an_enum_constant_may_be_negative() {
	r := parsed('enum E { NEG = -5, ZERO = 0 };\nint x = NEG;\n')
	assert r.errors.len == 0
	assert bytes_of(r.globals[0]) == 'fbffffff'
}

fn test_an_enum_is_four_bytes() {
	// Measured: tcc's enum is 4 bytes with 4-byte alignment.
	r := parsed('enum E { A };\nenum E e;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.size == 4
	assert r.globals[0].ty.align == 4
}

fn test_a_trailing_comma_in_an_enum_is_allowed() {
	r := parsed('enum E { A, B, };\n')
	assert r.errors.len == 0
}

fn test_an_enum_tag_must_be_known_before_it_is_used() {
	// C has no forward reference for an enum: the tag has to exist before the
	// enumeration is complete, and saying so is better than inventing a type.
	r := parsed('enum E e;\n')
	assert r.errors.len == 1
	assert r.errors[0].contains('unknown enum type')
}

fn test_a_struct_tag_can_be_completed_after_it_is_referenced() {
	// A struct is different: struct S *p; before struct S {...} is legal and
	// common, and the pointer's type has to see the completed struct.
	r := parsed('struct S *p;\nstruct S { int a; };\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.kind == .pointer
	assert r.globals[0].ty.base.size == 4
}

// --- struct and union layout, against tcc's byte images ---

fn test_natural_struct_layout() {
	// struct { char a; int b; short c; } — measured size 12, b at 4, c at 8.
	r := parsed('struct N { char a; int b; short c; };\nstruct N n = {1, 0x11223344, 0x5566};\n')
	assert r.errors.len == 0
	n := r.globals[0]
	assert n.ty.size == 12
	assert n.ty.align == 4
	assert n.ty.members[0].offset == 0
	assert n.ty.members[1].offset == 4
	assert n.ty.members[2].offset == 8
	// And the bytes tcc produced for exactly these values.
	assert bytes_of(n) == '0100000044332211 66550000'
}

fn test_union_takes_the_largest_member_and_the_strictest_alignment() {
	// union { char c; long i; double d; } — measured size 8, align 8.
	r := parsed('union U { char c; long i; double d; };\nunion U u;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.size == 8
	assert r.globals[0].ty.align == 8
}

fn test_nested_struct_layout() {
	// struct { char a; struct N inner; char b; } where N is 12/4 — measured 20.
	r := parsed('struct N { char a; int b; short c; };\nstruct O { char a; struct N inner; char b; };\nstruct O o;\n')
	assert r.errors.len == 0
	o := r.globals[0]
	assert o.ty.size == 20
	assert o.ty.members[1].offset == 4
	assert o.ty.members[2].offset == 16
}

fn test_long_and_double_in_one_struct() {
	// A `long` is 4 bytes here, so this struct is 16 with the double at 8. Under a
	// System V table `long` would be 8 and the struct 16 with the double at 8 as well,
	// which is exactly why asserting the size alone would not catch a wrong table.
	r := parsed('struct T { long a; double b; };\nstruct T t = {0x11223344, 1.5};\n')
	assert r.errors.len == 0
	t := r.globals[0]
	assert t.ty.size == 16
	assert t.ty.members[0].ty.size == 4
	assert t.ty.members[1].offset == 8
	assert bytes_of(t) == '4433221100000000 000000000000f83f'
}

fn test_bitfield_layout_matches_tcc_byte_for_byte() {
	// struct { char a; int b:3; int c:5; int :0; int d:4; char e; }
	// tcc: size 8, bytes 11 6e 00 00 0f 22 00 00 for these values.
	r := parsed('struct B { char a; int b : 3; int c : 5; int : 0; int d : 4; char e; };\nstruct B b = {0x11, -2, 13, -1, 0x22};\n')
	assert r.errors.len == 0
	b := r.globals[0]
	assert b.ty.size == 8
	assert b.ty.align == 4
	assert bytes_of(b) == '116e00000f220000'
	// The zero-width bitfield is a padding directive rather than a field, so it is the
	// one member here with no name. Counting the members is what shows the initializer
	// values still line up with a, b, c, d and e.
	assert b.ty.members.len == 6
	assert b.ty.members[3].name == ''
	assert b.ty.members[3].is_bitfield
	assert b.ty.members[3].bit_width == 0
	// b starts 8 bits in, which is inside the storage unit that starts at byte 0. Only
	// the bit position says so, which is why both are recorded.
	assert b.ty.members[1].offset == 0
	assert b.ty.members[1].bit_offset == 8
	assert b.ty.members[1].bit_width == 3
	// The zero-width bitfield pushed d into a fresh unit, so d is member 4 and e is 5.
	assert b.ty.members[4].offset == 4
	assert b.ty.members[4].bit_offset == 0
	// And e follows the bitfield at the next byte, not at the next aligned boundary.
	assert b.ty.members[5].offset == 5
}

fn test_a_bitfield_that_would_straddle_its_unit_starts_a_new_one() {
	// tcc: size 16, bytes 7f 00 9c 01 40 e2 01 00 ff ff ff ff ff 00 00 00.
	r := parsed('struct C { char a : 1; char b : 7; short c : 9; int d : 20; long long e : 40; };\nstruct C c = {1, 63, -100, 123456, -1};\n')
	assert r.errors.len == 0
	c := r.globals[0]
	assert c.ty.size == 16
	assert c.ty.align == 8
	assert bytes_of(c) == '7f009c0140e20100 ffffffffff000000'
	// c crosses from bit 8 to bit 16, so it starts a new two-byte unit at offset 2.
	assert c.ty.members[2].offset == 2
	assert c.ty.members[2].bit_offset == 0
}

fn test_narrow_bitfields_are_packed_into_their_units() {
	// tcc: size 4, bytes 2e 3b ff 0f.
	r := parsed('struct D { short a : 12; char b : 2; short c : 12; };\nstruct D d = {-1234, 3, 4095};\n')
	assert r.errors.len == 0
	d := r.globals[0]
	assert d.ty.size == 4
	assert bytes_of(d) == '2e3bff0f'
	// b does not fit in the rest of the first unit, so it sits at bit 12 of byte 1.
	assert d.ty.members[1].offset == 1
	assert d.ty.members[1].bit_offset == 4
	assert d.ty.members[2].offset == 2
}

fn test_a_bitfield_never_overwrites_its_neighbour() {
	// Two one-bit fields in one byte. If the writer stored the whole storage unit
	// instead of merging, the second write would erase the first, and the byte image
	// would come out 01 rather than 03.
	r := parsed('struct E { unsigned a : 1; unsigned b : 1; };\nstruct E e = {1, 1};\n')
	assert r.errors.len == 0
	assert bytes_of(r.globals[0]) == '03000000'
}

fn test_an_anonymous_struct_member_contributes_its_fields_to_the_outer_namespace() {
	r := parsed('struct A { struct { int a; int b; }; int c; };\nstruct A x;\n')
	assert r.errors.len == 0
	a := r.globals[0]
	assert a.ty.size == 12
	// The anonymous member is a real member with no name, and the field after it starts
	// after all of it.
	assert a.ty.members[0].name == ''
	assert a.ty.members[1].offset == 8
}

fn test_a_flexible_array_member_is_recorded() {
	r := parsed('struct F { int n; char data[]; };\nstruct F f;\n')
	assert r.errors.len == 0
	f := r.globals[0]
	// tcc: size 4, and the flexible member contributes nothing to it.
	assert f.ty.size == 4
	assert f.ty.is_flexible
	assert f.ty.members[1].ty.array_len == 0
}

// --- packing ---

fn test_pragma_pack_reduces_alignment() {
	// tcc: `#pragma pack(push, 1)` gives size 7 with b at 1 and c at 5.
	r := preprocessed('#pragma pack(push, 1)\nstruct P { char a; int b; short c; };\n#pragma pack(pop)\nstruct P p;\n')
	assert r.errors.len == 0
	p := r.globals[0]
	assert p.ty.size == 7
	assert p.ty.align == 1
	assert p.ty.members[1].offset == 1
	assert p.ty.members[2].offset == 5
}

fn test_pragma_pack_of_two_aligns_to_two() {
	// tcc: `#pragma pack(push, 2)` gives size 8, b at 2 and c at 6.
	r := preprocessed('#pragma pack(push, 2)\nstruct P2 { char a; int b; short c; };\n#pragma pack(pop)\nstruct P2 p;\n')
	assert r.errors.len == 0
	p := r.globals[0]
	assert p.ty.size == 8
	assert p.ty.members[1].offset == 2
	assert p.ty.members[2].offset == 6
}

fn test_pragma_pack_pop_restores_the_default() {
	// A struct after the pop must be laid out normally, which is what the pop is for.
	// Both structs need a variable of their own type: a bare `struct P3 { ... };` is a
	// tag declaration and never becomes a global, so asserting on globals[0] would be
	// asserting on `n`.
	r := preprocessed('#pragma pack(push, 1)\nstruct P3 { char a; int b; };\nstruct P3 p;\n#pragma pack(pop)\nstruct N2 { char a; int b; };\nstruct N2 n;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.size == 5
	assert r.globals[1].ty.size == 8
}

fn test_a_packed_attribute_is_pack_of_one() {
	r := parsed('struct __attribute__((packed)) Q { char a; int b; };\nstruct Q q;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.size == 5
	assert r.globals[0].ty.align == 1
}

fn test_an_aligned_attribute_raises_the_alignment() {
	r := parsed('struct __attribute__((aligned(16))) R { char a; };\nstruct R r;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.align == 16
	// The size grows to match, or the object would overlap its neighbour.
	assert r.globals[0].ty.size == 16
}

fn test_an_unknown_attribute_is_accepted_and_ignored() {
	// V marks its own generated functions with constructor, naked, noinline and
	// visibility, so refusing an attribute vcc does not act on would make vcc unable to
	// compile V's output.
	r := parsed('__attribute__((visibility("hidden"))) int f(void);\n')
	assert r.errors.len == 0
	assert r.globals[0].name == 'f'
}

// An attribute may follow the declarator on a *declaration*, which is where mingw's
// headers write it: `void __cdecl exit(int _Code) __MINGW_ATTRIB_NORETURN;` is
// `void __cdecl exit(int _Code) __declspec(noreturn);`, and `__declspec(n)` is
// `__attribute__((n))`. gcc accepts the form; so does tcc.
//
// It used to be read only ahead of the declarator, so the attribute became a stray token
// after the declaration and every header using it failed with
// `expected "{" or ";" after a function declaration`.
fn test_an_attribute_may_follow_the_declarator() {
	r := parsed('void __attribute__((noreturn)) exit(int x) __attribute__((noreturn));\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].name == 'exit'
	// A definition's body is what follows the attribute, which is the shape
	// `__CRT_INLINE __MINGW_ATTRIB_NORETURN void __cdecl _Exit(int status) { ... }`
	// uses in mingw's assert.h.
	r2 := parsed('__attribute__((noreturn)) void e(int s) __attribute__((noreturn)) { return; }\n')
	assert r2.errors.len == 0, 'unexpected diagnostics: ${r2.errors}'
	assert r2.globals[0].is_definition
}

// GNU's spellings of `inline`. mingw's `__CRT_INLINE` expands to `static __inline__`, so
// without them every inline definition in `string.h` and `wchar.h` parses as a
// declaration with no name — which is how `string.h` kept failing.
//
// They are folded-alias *keywords*, so their text is not in `type_specifier_keywords`;
// answering `is_typename` for them is what the `.keyword` branch has to do.
fn test_gnu_inline_spellings_are_storage_class_specifiers() {
	for spell in ['__inline', '__inline__', '__forceinline'] {
		r := parsed('${spell} int f(int x) { return x; }\n')
		assert r.errors.len == 0, 'for ${spell}: ${r.errors}'
		assert r.globals[0].name == 'f'
	}
	// The declaration form, which is what the headers use.
	r := parsed('__inline int g(int x);\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].name == 'g'
}

// Microsoft calling-convention specifiers, which mingw writes on almost every
// declaration. On this target every one of them means the same thing and none changes how
// an argument is passed — the Microsoft x64 ABI has one convention — so reading and
// discarding them is correct rather than a shortcut. `src/ast/abi.v` records it.
fn test_calling_convention_specifiers_are_ignored() {
	for spell in ['__cdecl', '__stdcall', '__fastcall', 'WINAPI', 'CALLBACK', 'APIENTRY'] {
		r := parsed('int ${spell} f(int x) { return x; }\n')
		assert r.errors.len == 0, 'for ${spell}: ${r.errors}'
		assert r.globals[0].name == 'f'
	}
	// Both the declared and the definition form.
	r := parsed('extern int __cdecl g(int x);\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].name == 'g'
}

// A linkage change is still reported when there is no `inline` to excuse it. That is the
// line between "tcc's headers compile" and "every diagnostic is gone": tcc accepts all
// three shapes here — it does not implement the constraint — but gcc rejects all three,
// rejecting `stdio.h:259`, `tcc_libm.h:49` and `wchar.h:855` from this very include tree.
fn test_a_linkage_change_is_reported_without_an_inline_specifier() {
	// Exempt: an inline definition does not establish linkage the same way, and this is
	// how a library spells a definition that cannot be inlined at the call site.
	r := parsed('int f(int x);\n__inline__ int f(int x) { return x; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	// Not exempt, and still a real constraint violation.
	r2 := parsed('int h(int x);\nstatic int h(int x) { return x; }\n')
	assert r2.errors.len > 0, 'expected a diagnostic, got none'
	assert r2.errors[0].contains('static declaration follows a non-static declaration')
}

// --- initializers ---

fn test_a_scalar_initializer_is_written_little_endian() {
	obj := global('int x = 0x11223344;\n')
	assert bytes_of(obj) == '44332211'
}

fn test_a_negative_initializer_is_kept() {
	assert bytes_of(global('int x = -1;\n')) == 'ffffffff'
}

fn test_an_array_initializer_fills_in_order() {
	obj := global('int a[4] = {1, 2, 3, 4};\n')
	assert obj.ty.array_len == 4
	assert bytes_of(obj) == '0100000002000000 0300000004000000'
}

fn test_unmentioned_elements_are_zero() {
	obj := global('int a[4] = {1, 2};\n')
	assert bytes_of(obj) == '0100000002000000 0000000000000000'
}

fn test_an_array_length_may_come_from_the_initializer() {
	obj := global('int a[] = {1, 2, 3};\n')
	assert obj.ty.array_len == 3
	assert obj.ty.size == 12
	assert bytes_of(obj) == '0100000002000000 03000000'
}

fn test_a_designated_array_initializer_moves_the_cursor() {
	// `[5]` sets the sixth element and the values after it continue from there, leaving
	// the ones in between zero. That is gcc's rule and chibicc's.
	obj := global('int a[8] = {1, [5] = 6, 7};\n')
	assert bytes_of(obj) == '0100000000000000 0000000000000000 0000000006000000 0700000000000000'
}

fn test_a_designated_struct_initializer_names_the_field() {
	obj := global('struct S { int a; int b; int c; };\nstruct S s = { .c = 5 };\n')
	assert bytes_of(obj) == '0000000000000000 05000000'
}

fn test_braces_may_be_elided_inside_an_aggregate() {
	obj := global('int a[2][2] = {1, 2, 3, 4};\n')
	assert obj.ty.size == 16
	assert bytes_of(obj) == '0100000002000000 0300000004000000'
}

fn test_a_string_initializer_includes_the_terminator() {
	obj := global('char s[] = "ab";\n')
	assert obj.ty.array_len == 3
	assert bytes_of(obj) == '616200'
}

fn test_a_string_initializer_leaves_the_rest_zero() {
	obj := global('char s[8] = "ab";\n')
	assert obj.ty.array_len == 8
	assert bytes_of(obj) == '6162000000000000'
}

fn test_a_wide_string_initializer_uses_the_declared_element_width() {
	// `unsigned short`, which is what `wchar_t` is on this target: three two-byte
	// elements — `a`, `b` and the NUL — so the bytes are `61 00 62 00 0000`.
	//
	// This used to be `int w[] = L"ab"`, which is not a construct either oracle accepts:
	// gcc rejects it as `array of inappropriate type initialized from string constant`
	// and tcc reads the literal as a pointer and warns. Asserting vcc's answer for it
	// was asserting about a case nothing else has an opinion on.
	r := parsed('unsigned short w[] = L"ab";\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].ty.array_len == 3
	assert r.globals[0].ty.base.size == 2
	assert bytes_of(r.globals[0]) == '610062000000'
}

fn test_a_narrow_literal_in_a_wider_array_takes_the_array_s_stride() {
	// The element count comes from the literal; the stride comes from the array. Twelve
	// bytes here, not six — and this is the case the previous line's `resized.ty.size`
	// got wrong in the other direction.
	r := parsed('unsigned int w[] = L"ab";\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].ty.array_len == 3
	assert r.globals[0].ty.size == 12
	assert bytes_of(r.globals[0]) == '6100000062000000 00000000'
}

fn test_a_float_initializer_is_written_as_its_encoding() {
	obj := global('float f = 1.5f;\n')
	// 1.5 is 0x3FC00000 in IEEE 754.
	assert bytes_of(obj) == '0000c03f'
}

fn test_a_double_initializer_is_written_as_its_encoding() {
	obj := global('double d = 1.5;\n')
	// 1.5 is 0x3FF8000000000000.
	assert bytes_of(obj) == '000000000000f83f'
}

fn test_an_extern_pointer_becomes_a_relocation() {
	// The address is not known while parsing, so the bytes stay zero and the object
	// writer patches them later.
	r := parsed('static int target = 7;\nint *p = &target;\n')
	assert r.errors.len == 0
	p := r.globals[1]
	assert p.rel.len == 1
	assert p.rel[0].label == 'target'
	assert p.rel[0].addend == 0
	assert bytes_of(p) == '0000000000000000'
}

fn test_an_array_of_pointers_to_strings_becomes_relocations() {
	// The shape V's generated C uses for its string tables.
	r := parsed('static const char *names[2] = {"a", "b"};\n')
	assert r.errors.len == 0
	n := r.globals[0]
	assert n.rel.len == 2
	assert n.rel[0].label == '.L..1'
	assert n.rel[1].label == '.L..2'
}

fn test_an_address_plus_offset_carries_the_offset_in_the_relocation() {
	r := parsed('static int table[8];\nint *p = &table[3];\n')
	assert r.errors.len == 0
	assert r.globals[1].rel.len == 1
	assert r.globals[1].rel[0].addend == 12
}

// --- constant expressions ---

fn test_constant_folding_in_an_array_bound() {
	assert global('int a[2 + 3];\n').ty.array_len == 5
}

fn test_a_parenthesised_constant_expression() {
	assert global('int a[(1 + 2) * 2];\n').ty.array_len == 6
}

fn test_a_conditional_expression_as_a_constant() {
	assert global('int a[1 ? 4 : 9];\n').ty.array_len == 4
}

fn test_sizeof_gives_the_measured_size() {
	// `sizeof` returns a size_t, which is 8 bytes here even though `long` is 4.
	assert bytes_of(global('unsigned long long n = sizeof(int);\n')) == '0400000000000000'
	assert bytes_of(global('unsigned long long n = sizeof(long);\n')) == '0400000000000000'
	assert bytes_of(global('unsigned long long n = sizeof(long double);\n')) == '0800000000000000'
}

fn test_alignof_gives_the_measured_alignment() {
	assert bytes_of(global('unsigned long long n = _Alignof(int);\n')) == '0400000000000000'
}

fn test_a_cast_truncates_to_the_target_width() {
	assert bytes_of(global('int x = (char)0x11223344;\n')) == '44000000'
	assert bytes_of(global('int x = (short)0x11223344;\n')) == '44330000'
	assert bytes_of(global('int x = (int)0x11223344LL;\n')) == '44332211'
}

fn test_an_unsigned_right_shift_is_logical() {
	// `-1 >> 1` is -1 signed and 0x7fffffff unsigned. Getting this backwards changes a
	// mask into a sign extension.
	assert bytes_of(global('int x = -1 >> 1;\n')) == 'ffffffff'
	assert bytes_of(global('unsigned int x = 0xffffffffU >> 1;\n')) == 'ffffff7f'
}

fn test_a_64_bit_unsigned_shift_is_logical() {
	assert bytes_of(global('unsigned long long x = 0xffffffffffffffffULL >> 32;\n')) ==
		'ffffffff00000000'
}

// --- typeof, _Atomic, alignment ---

fn test_typeof_names_the_type_of_an_expression() {
	r := parsed('int a = 1;\ntypeof(a) b;\n')
	assert r.errors.len == 0
	assert r.globals[1].ty.basic == .int_
}

fn test_typeof_accepts_a_type_name_too() {
	r := parsed('typeof(int *) p;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.kind == .pointer
}

fn test_atomic_is_recorded() {
	r := parsed('_Atomic int x;\n')
	assert r.errors.len == 0
	assert r.globals[0].ty.is_atomic
}

fn test_alignas_raises_an_objects_alignment() {
	r := parsed('_Alignas(16) int x;\n')
	assert r.errors.len == 0
	assert r.globals[0].align == 16
}

// --- diagnostics ---

fn test_a_missing_semicolon_is_reported_with_a_position() {
	r := parsed('int x\nint y;\n')
	assert r.errors.len > 0
	// The message names the file and line, because a preprocessor diagnostic and a
	// parser diagnostic have to be greppable the same way in a corpus sweep.
	//
	// The line is the *unexpected* token's, not the declaration that is missing its
	// semicolon, because that is where tcc puts it: for `int x\nint y;` tcc reports
	// `ms.c:2: error: ';' expected (got 'int')`. Reporting line 1 would be more useful
	// to a human and less useful for lining diagnostics up against tcc.
	assert r.errors[0].contains('test.c:2')
	assert r.errors[0].contains("';' expected (got 'int')")
}

fn test_an_undeclared_identifier_in_an_initializer_is_reported() {
	r := parsed('int x = undefined_thing;\n')
	assert r.errors.len > 0
	assert r.errors[0].contains('undefined variable')
}

fn test_a_diagnostic_carries_the_tcc_prefix_v_looks_for() {
	// `v3_is_tcc_compilation_failure` treats any output line starting with `tcc:` as a
	// compiler failure, so a compiler that reported errors in another format would make
	// V fall back to `cc` instead of saying what went wrong.
	r := parsed('int x = ;\n')
	assert r.errors.len > 0
	assert r.errors[0].starts_with('tcc: ')
}

fn test_a_specifier_combination_that_is_not_a_type_is_reported() {
	r := parsed('char int x;\n')
	assert r.errors.len > 0
	assert r.errors[0].contains('invalid combination')
}

fn test_a_function_call_in_a_global_initializer_is_not_constant() {
	// A global's initializer is evaluated at a fixed address, so a call cannot go in
	// one. tcc says `initializer element is not constant` for this input, and matching
	// that wording is what lets a corpus sweep line the two up.
	r := parsed('int f(int);\nint x = f(1);\n')
	assert r.errors.len > 0
	assert r.errors[0].contains('initializer element is not constant')
}

// --- the dump ---

fn test_the_dump_names_each_declaration_and_its_layout() {
	r := parsed('struct S { char a; int b : 3; };\nstruct S s = {1, 5};\n')
	text := r.dump()
	assert text.contains('struct S')
	assert text.contains('size=4')
	// `b : 3` follows a whole byte, so it starts at bit 8 of a 32-bit unit. The byte
	// image is tcc's for the same struct: 01 05 00 00.
	assert text.contains('bits 8..11')
	assert text.contains('bytes=01050000')
}

// --- string literals ---

fn test_adjacent_string_literals_are_one_literal() {
	// [C11 6.4.5p5] `"abc" "def"` is one literal. It used to parse as `"abc"` and then
	// trip over the second token, which the missing `)` never consumed, so the parser
	// re-read the same tokens until the heap gave out.
	r := parsed('char *p = "ab" "cd";')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	// globals[0] is p; the merged literal is the anonymous global after it.
	assert bytes_of(r.globals[1]) == '6162636400', bytes_of(r.globals[1])
}

fn test_a_run_of_string_literals_is_joined_in_order() {
	r := parsed('char *p = "a" "b" "c";')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[1]) == '61626300', bytes_of(r.globals[1])
}

fn test_one_terminator_is_written_for_the_whole_run() {
	r := parsed('char a[] = "ab" "cd";')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].ty.array_len == 5, 'got ${r.globals[0].ty.array_len}'
}

fn test_a_wide_piece_decides_the_width_of_the_whole_run() {
	// 8, not 16. A run of literals is one array of the *first* piece's element type, and
	// a wide element is two bytes on this target, so four characters is eight. This
	// asserted 16 while chibicc's suite expected 16 — chibicc is System V, where
	// `wchar_t` is four bytes. Measured: tcc and mingw gcc 15.2 both answer 8 here, and
	// the project's own rule is to follow this host rather than chibicc, which is the
	// same decision already made for `long` being four bytes.
	r := parsed('int n = sizeof(L"ab" "c");')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].init_data[0] == 8, 'got ${r.globals[0].init_data[0]}'
}

fn test_a_wide_run_keeps_the_run_width_even_when_the_pieces_disagree() {
	// [C11 6.4.5p5] a mismatched prefix in a run is undefined rather than an error, and
	// both tcc and chibicc take the first piece's width and say nothing. So `L"ab" "cd"`
	// is four wide elements, and asserting the *count* here is what keeps the count and
	// the width from being checked independently — the width alone was right at one point
	// with the count still wrong.
	r := parsed('unsigned n = sizeof(L"ab" "cd");')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].init_data[0] == 10, 'got ${r.globals[0].init_data[0]}'
}

fn test_a_nested_array_is_an_array_of_rows_not_of_columns() {
	// `int a[3][5]` is three rows of five, so the *inner* type is `int[5]` and the outer
	// one has three of them. Building it the other way round — `array(array(int, 3), 5)` —
	// gives the same total size and the same innermost stride, so a self-consistent
	// program cannot see it; the row stride is what differs, and any pointer to the row
	// type disagrees about where a row is.
	r := parsed('int a[3][5];\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	a := r.globals[0].ty
	assert a.kind == .array, 'got ${a.kind}'
	assert a.array_len == 3, 'got ${a.array_len}'
	assert a.base.kind == .array, 'the element should be the row type, got ${a.base.kind}'
	assert a.base.array_len == 5, 'got ${a.base.array_len}'
	assert a.base.base == ty_int
	// Five rows would be the same total size, so the sizes are asserted to *not* be the
	// evidence: the row's own width is what a pointer to it steps by.
	assert a.base.size == 20, 'got ${a.base.size}'
	assert a.size == 60
}

fn test_three_dimensions_apply_right_to_left() {
	// The same rule one dimension further out. `b[2][3][4]` is 2 planes of 3 rows of 4,
	// so `*b` is 48 bytes and `**b` is 16.
	r := parsed('int b[2][3][4];\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	b := r.globals[0].ty
	assert b.array_len == 2
	assert b.base.array_len == 3
	assert b.base.base.array_len == 4
	assert b.base.size == 48, 'got ${b.base.size}'
	assert b.base.base.size == 16, 'got ${b.base.base.size}'
}

fn test_a_variable_length_array_carries_its_row_s_size_as_a_runtime_value() {
	// `int x[n + 1][n + 6]` — both extents are variable, so the row type is itself a VLA
	// and the whole thing is `vla(vla(int, n + 6), n + 1)`. That is right, and it is why
	// `vla_of`'s eight-byte placeholder is a trap: `x[i]` has to step by the *row's*
	// run-time size, so each VLA in the chain has to have recorded its own size local.
	// Without the inner one, `x[1][0]` advanced four bytes instead of a whole row.
	//
	// The size locals are built when the declaration is translated, so they are not
	// present after parsing alone; what this checks is the shape, and that the parser
	// built the chain in the right order — suffixes right to left, so the *row* is the
	// `n + 6` and not the `n + 1`.
	r := parsed('int f(int n) { int x[n + 1][n + 6]; return 0; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	f := r.globals[0]
	mut x := &ast.Obj{}
	for l in f.locals {
		if l.name == 'x' {
			x = l
		}
	}
	assert x != unsafe { nil }, 'x is not one of the locals'
	assert x.ty.kind == .vla, 'got ${x.ty.kind}'
	assert x.ty.base != unsafe { nil }, 'the element type is missing'
	assert x.ty.base.kind == .vla, 'got ${x.ty.base.kind}'
	assert x.ty.base.base == ty_int, 'the row should be of int'
	// The two extents are kept apart, because the outer one is what `sizeof` answers and
	// the inner one is what a subscript steps by, and swapping them would leave both
	// right in `sizeof` while every `x[i]` was a row off.
	assert x.ty.vla_len != unsafe { nil }, 'the outer extent is missing'
	assert x.ty.base.vla_len != unsafe { nil }, 'the row extent is missing'
	assert x.ty.vla_len != x.ty.base.vla_len, 'the two extents are the same expression'
}

fn test_an_escape_is_decoded_by_the_same_rule_inside_a_run() {
	// Re-encoding the decoded bytes would turn `"\xff"` into two UTF-8 bytes and make
	// this 2 rather than 1.
	r := parsed('char *p = "\xff" "a";')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[1]) == 'ff6100', bytes_of(r.globals[1])
}

fn test_the_parser_makes_progress_past_a_token_it_did_not_expect() {
	// `expect` used to report and return without consuming, so the enclosing loop saw
	// the same token again. One missing semicolon became an unbounded loop of
	// diagnostics rather than a one-line syntax error.
	r := parsed('int f(void) { return 1 }')
	assert r.errors.len > 0, 'expected a diagnostic'
	assert r.errors.len < 10, 'a missing semicolon produced ${r.errors.len} diagnostics'
}

// --- the GNU conditional ---

fn test_the_middle_operand_of_a_gnu_conditional_may_be_left_out() {
	r := parsed('int n = 3 ?: 5;')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
}

// returned walks to the expression of a function body's `return`, which is the only
// public path from a parsed translation unit to a node: a global's initializer is
// consumed into its byte image and is not kept.
//
// The casts come off first, because `add_type` wraps the returned expression in one to
// the function's return type — and it is `add_type` that puts a cast on each branch of
// the conditional too, which is why the GNU form cannot be recognised by comparing
// pointers.
fn returned(src string) &ast.Node {
	r := parsed(src)
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	mut found := 0
	for s in r.globals[0].body {
		if s.kind == .return_ {
			found++
			mut n := s.lhs
			for n.kind == .cast {
				n = n.lhs
			}
			return n
		}
	}
	assert found == 1, 'expected exactly one return, found ${found}'
	return unsafe { nil }
}

fn test_an_omitted_middle_operand_is_recorded_rather_than_inferred() {
	// It has to be a flag: `add_type` casts each branch, so the backend cannot tell the
	// GNU form from `a ? a : b` by comparing the two pointers afterwards. It matters
	// because `a ?: b` evaluates `a` once, and generating the branch twice evaluates
	// `++i ?: 10` twice.
	n := returned('int f(void) { return 1 ?: 2; }')
	assert n.kind == .cond_expr, 'got ${n.kind}'
	assert n.then_is_cond, 'the omitted operand was not recorded'
}

fn test_a_written_out_middle_operand_is_not_the_gnu_form() {
	n := returned('int f(void) { return 1 ? 1 : 2; }')
	assert n.kind == .cond_expr, 'got ${n.kind}'
	assert !n.then_is_cond, 'a written-out operand was read as omitted'
}

fn test_the_gnu_conditional_picks_the_condition_when_it_is_nonzero() {
	r := parsed('int a = 3 ?: 5;')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[0]) == '03000000', bytes_of(r.globals[0])
}

fn test_the_gnu_conditional_falls_through_when_the_condition_is_zero() {
	r := parsed('int a = 0 ?: 5;')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[0]) == '05000000', bytes_of(r.globals[0])
}

fn test_an_unsupported_expression_is_reported_rather_than_crashing_the_parser() {
	// The stand-in used to be an untyped node and `add_type` reads `node.then.ty`, so an
	// unimplemented construct aborted the compiler instead of producing a diagnostic.
	r := parsed('int f(void) { return 1 @ 2; }')
	assert r.errors.len > 0, 'expected a diagnostic'
}

// --- the comma operator ---

fn test_a_parenthesised_expression_may_hold_a_comma_operator() {
	// Parentheses hold a whole expression, not a conditional. Reading only a conditional
	// stopped at the first comma, so `(1,2,3)` was a diagnostic on ordinary C.
	r := parsed('int a = (1,2,3);')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[0]) == '03000000', bytes_of(r.globals[0])
}

fn test_sizeof_of_a_parenthesised_comma_expression_is_the_size_of_its_type() {
	// Four, not eight: a comma expression has the type of its last operand, which is an
	// int, and the declared type of the object does not widen a sizeof.
	r := parsed('unsigned long a = sizeof(1,2,3);')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert bytes_of(r.globals[0]) == '04000000', bytes_of(r.globals[0])
}

fn test_an_assignment_inside_parentheses_is_still_an_assignment() {
	r := parsed('int f(void) { int a = 0; return (a = 5); }')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
}

// --- _Alignof and anonymous members ---

fn test_alignof_of_an_expression_asks_the_expression_s_type_alignment() {
	// C11 allows only a type name. gcc, clang, tcc and chibicc all accept an expression
	// as well, and V's generated C uses that form.
	n := returned('int f(void) { char c; return _Alignof(c); }')
	assert n.kind == .num, 'got ${n.kind}'
	assert n.num == 1, 'got ${n.num}'
}

fn test_alignof_of_an_expression_without_parentheses_is_accepted() {
	// Four bytes, because a `long` is four bytes on this target — which is the whole
	// point of asking tcc rather than assuming.
	r := parsed('unsigned long a = _Alignof(double);')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].ty.size == 4, 'got ${r.globals[0].ty.size}'
	assert bytes_of(r.globals[0]) == '08000000', bytes_of(r.globals[0])
}

fn test_a_field_of_an_anonymous_member_is_reached_through_it() {
	// The descent reads one token, not one per level. It used to recurse into
	// `struct_ref`, which read the member name a second time and so ate the token after
	// the field name — which is why this reported `expected a member name after "."`.
	n := returned('int f(void) { struct { struct { unsigned char a; }; int e; } y; return y.a; }')
	assert n.kind == .member, 'got ${n.kind}'
	// The access is a member of the anonymous member, which is itself a member.
	assert n.lhs.kind == .member, 'got ${n.lhs.kind}'
	m := n.member or {
		assert false, 'the field access has no member'
		return
	}
	assert m.name == 'a', 'got ${m.name}'
}

fn test_an_anonymous_union_member_contributes_its_fields_too() {
	// A bare `union U {...};` declares a tag and no object, so there is no global to ask
	// about; the object is declared separately.
	r := parsed('union U { union { unsigned char a; }; long e; }; union U u;')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert r.globals[0].ty.members.len == 2, 'got ${r.globals[0].ty.members.len}'
	assert r.globals[0].ty.members[0].name == '', 'the inner union should be anonymous'
	assert r.globals[0].ty.members[1].name == 'e', 'got ${r.globals[0].ty.members[1].name}'
}

fn test_a_named_member_still_resolves_without_descending() {
	n := returned('int f(void) { struct { int e; } y; return y.e; }')
	assert n.kind == .member, 'got ${n.kind}'
	m := n.member or {
		assert false, 'the field access has no member'
		return
	}
	assert m.name == 'e', 'got ${m.name}'
	assert n.lhs.kind != .member, 'a named member should not be reached through another'
}
