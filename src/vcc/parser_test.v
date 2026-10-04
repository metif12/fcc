module vcc

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

fn test_a_wide_string_initializer_uses_four_byte_elements() {
	// `L"ab"` is three elements of four bytes: the bytes tcc stores are the code points
	// little-endian, with the NUL last.
	obj := global('int w[] = L"ab";\n')
	assert obj.ty.array_len == 3
	assert obj.ty.base.size == 4
	assert bytes_of(obj) == '6100000062000000 00000000'
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