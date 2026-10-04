module vcc

import ast

// Type system tests.
//
// The sizes and alignments asserted here were measured from the bundled tcc rather
// than taken from a specification, because two of them are wrong in every
// specification that assumes System V: on this target `long` is 4 bytes and
// `long double` is 8. A test asserting what the C standard says would pass on Linux
// and produce silently mis-sized objects on Windows, which is the failure this file
// exists to prevent. See notes/DECISIONS.md D20 for the probe and its output.

// first_token tokenizes a fragment and returns its first token, which is how a test
// names a literal the way the lexer would have produced it.
fn first_token(src string) ast.Token {
	return tokenize(src)[0]
}

// bin_node builds a binary operator node over two already-typed operands, which is
// what `add_type` needs to work out a result type.
fn bin_node(kind ast.NodeKind, lhs_ty &ast.Type, rhs_ty &ast.Type) &ast.Node {
	return &ast.Node{
		kind: kind
		lhs:  &ast.Node{kind: .num, tok: first_token('1'), ty: lhs_ty}
		rhs:  &ast.Node{kind: .num, tok: first_token('1'), ty: rhs_ty}
	}
}

// common_of exposes the internal usual-arithmetic-conversion rule to tests.
fn common_of(a &ast.Type, b &ast.Type) &ast.Type {
	return get_common_type(a, b)
}

fn test_basic_type_sizes_are_the_measured_ones() {
	assert ty_void.size == 1
	assert ty_bool.size == 1
	assert ty_char.size == 1
	assert ty_short.size == 2
	assert ty_int.size == 4
	assert ty_long.size == 4
	assert ty_llong.size == 8
	assert ty_float.size == 4
	assert ty_double.size == 8
	assert ty_ldouble.size == 8
}

fn test_long_and_long_long_are_different_widths() {
	// The whole reason `long` and `long long` are separate kinds here: collapsing
	// them would mis-size every 64-bit constant V emits.
	assert ty_long.size == 4
	assert ty_llong.size == 8
	assert ty_long.size != ty_llong.size
}

fn test_basic_type_alignments() {
	assert ty_char.align == 1
	assert ty_short.align == 2
	assert ty_int.align == 4
	assert ty_llong.align == 8
	assert ty_double.align == 8
}

fn test_pointers_are_eight_bytes_and_unsigned() {
	p := pointer_to(ty_int)
	assert p.size == 8
	assert p.align == 8
	// A signed comparison of two addresses is a bug that only appears above 2GB, which
	// is why the pointer is unsigned.
	assert p.is_unsigned
}

fn test_void_has_size_one() {
	// GNU C defines `sizeof(void)` as 1, and the headers rely on it for `void *`
	// arithmetic.
	assert ty_void.size == 1
}

fn test_size_t_is_eight_bytes() {
	// `sizeof` returns a size_t, which is 8 bytes here even though `long` is 4.
	assert ty_size_t.size == 8
	assert ty_size_t.is_unsigned
}

fn test_array_size_is_the_product_of_length_and_element() {
	a := array_of(ty_int, 10)
	assert a.size == 40
	assert a.align == 4
	assert a.array_len == 10
	assert a.base == ty_int
}

fn test_array_of_unknown_length_has_no_size_yet() {
	a := array_of(ty_int, -1)
	assert a.array_len == -1
	// Not zero: an array whose length is not known yet is different from an array of
	// no elements, and `struct {}` is a real type of size zero.
	assert a.size == -1
}

fn test_size_or_known_distinguishes_unknown_from_zero() {
	assert array_of(ty_int, -1).size_or_known() == none
	// A zero-size type is real — `struct {}` is one — which is why "not computed yet"
	// cannot be spelled as zero.
	assert known_size(struct_type()) == 0
}

fn known_size(ty &ast.Type) int {
	return ty.size_or_known() or { -1 }
}

fn test_is_complete_agrees_with_size_or_known() {
	assert !array_of(ty_int, -1).is_complete()
	assert struct_type().is_complete()
	// A pointer is 8 bytes whatever it points at, so it is complete even when its
	// element type is not. That is why declaring `struct S *p;` before `struct S` is
	// legal in C, and why the completeness check a declaration needs looks at the type
	// itself rather than recursing.
	assert pointer_to(array_of(ty_int, -1)).is_complete()
}

fn test_is_integer_and_is_flonum() {
	assert is_integer(ty_int)
	assert is_integer(ty_bool)
	assert is_integer(ty_llong)
	assert !is_integer(ty_double)
	assert is_flonum(ty_double)
	assert is_flonum(ty_float)
	assert !is_flonum(ty_long)
	assert is_numeric(ty_int)
	assert is_numeric(ty_double)
	assert !is_numeric(pointer_to(ty_int))
}

fn test_is_compatible_through_a_typedef() {
	// The property that makes `typedef int T;` work at all: a typedef and the type
	// it names are the same type, so a function declared one way and defined the
	// other is one function.
	alias := copy_type(ty_int)
	assert is_compatible(alias, ty_int)
	assert is_compatible(ty_int, alias)
}

fn test_signed_and_unsigned_are_not_compatible() {
	assert !is_compatible(ty_int, ty_uint)
	assert !is_compatible(ty_char, ty_uchar)
	// int and long are distinct types even though they are the same width on this
	// target. C's type identity does not depend on size, and _Generic depends on that
	// identity: an int controlling expression must not select a long association.
	assert is_compatible(ty_int, ty_long) == false
}

fn test_compatibility_is_structural_for_derived_types() {
	pi := pointer_to(ty_int)
	pi2 := pointer_to(ty_int)
	ps := pointer_to(ty_uint)
	assert is_compatible(pi, pi2)
	// A pointer to int is not a pointer to unsigned int, even though they have the same
	// size: that is exactly the bug this check prevents.
	assert !is_compatible(pi, ps)
}

fn test_array_compatibility_follows_length() {
	assert is_compatible(array_of(ty_int, 3), array_of(ty_int, 3))
	assert !is_compatible(array_of(ty_int, 3), array_of(ty_int, 4))
	// An array whose length is not known yet is compatible with any other array of
	// the same element type, which is how `int x[] = {1,2,3}` completes itself.
	assert is_compatible(array_of(ty_int, -1), array_of(ty_int, 3))
}

fn test_function_compatibility_compares_return_and_parameters() {
	mut a := func_type(ty_int)
	a.params = [ty_int, ty_char]
	a.is_variadic = false
	mut b := func_type(ty_int)
	b.params = [ty_int, ty_char]
	b.is_variadic = false
	mut c := func_type(ty_int)
	c.params = [ty_int]
	c.is_variadic = false
	mut d := func_type(ty_int)
	d.params = [ty_int, ty_char]
	d.is_variadic = true
	assert is_compatible(a, b)
	assert !is_compatible(a, c)
	// `printf` and a two-argument function are not the same symbol to the linker.
	assert !is_compatible(a, d)
}

fn test_copy_type_records_its_origin() {
	mut c := copy_type(ty_int)
	assert c.origin == ty_int
	// The copy is a distinct object, so a name can be attached to it without touching
	// the shared type every other declaration sees.
	c.name = 'x'
	assert ty_int.name == ''
}

fn test_add_type_gives_a_literal_the_type_its_spelling_implies() {
	mut plain := &ast.Node{kind: .num, tok: first_token('1')}
	add_type(mut plain)
	assert plain.ty == ty_int

	mut longs := &ast.Node{kind: .num, tok: first_token('1LL')}
	add_type(mut longs)
	assert longs.ty == ty_llong
}

fn test_add_type_promotes_a_short_to_int_in_a_binary_operator() {
	// `(char)x + (char)y` is an int addition, not a char one. That is the integer
	// promotion rule, and getting it wrong overflows at 8 bits.
	mut a := bin_node(.add, ty_char, ty_char)
	add_type(mut a)
	// The result is a *copy* of int rather than the int object itself, because
	// `new_cast` copies. Identity is therefore not the right question to ask about a
	// computed type, and a test that compares pointers would be asserting an
	// implementation detail.
	assert is_compatible(a.ty, ty_int)
	assert a.ty.basic == .int_
	assert a.ty.size == 4
}

fn test_add_type_makes_a_pointer_arithmetic_result_a_pointer() {
	mut a := bin_node(.add, pointer_to(ty_int), ty_int)
	add_type(mut a)
	assert a.ty.kind == .pointer
	assert a.ty.base == ty_int
}

fn test_add_type_leaves_a_set_type_alone() {
	mut node := &ast.Node{kind: .num, tok: first_token('1')}
	node.ty = ty_uint
	add_type(mut node)
	// Idempotence matters: the parser calls this whenever it needs a type.
	assert node.ty == ty_uint
}

fn test_common_type_promotes_to_the_wider_operand() {
	assert common_of(ty_int, ty_llong) == ty_llong
	assert common_of(ty_llong, ty_int) == ty_llong
	// Both operands are promoted to int first, and at equal width the unsigned one
	// wins. `char + unsigned char` is therefore an `int`, not an `unsigned int`: the
	// promotion happens first and throws away the narrower type's signedness.
	assert common_of(ty_char, ty_uchar) == ty_int
	assert common_of(ty_int, ty_uint) == ty_uint
	// Any floating operand wins, widest first.
	assert common_of(ty_int, ty_double) == ty_double
	assert common_of(ty_float, ty_double) == ty_double
}

fn test_align_to_and_align_down() {
	assert align_to(0, 4) == 0
	assert align_to(1, 4) == 4
	assert align_to(4, 4) == 4
	assert align_to(5, 4) == 8
	assert align_to(9, 8) == 16
	assert align_down(8, 4) == 8
	assert align_down(1, 4) == 0
	// A bitfield that starts partway into a byte still belongs to the unit below it,
	// which is what this is for.
	assert align_down(2, 4) == 0
	assert align_down(4, 4) == 4
}

fn test_numeric_literal_types() {
	assert numeric_type(first_token('1')) == ty_int
	assert numeric_type(first_token('1u')) == ty_uint
	assert numeric_type(first_token('1L')) == ty_long
	assert numeric_type(first_token('1LL')) == ty_llong
	assert numeric_type(first_token('1ULL')) == ty_ullong
	assert numeric_type(first_token('1.0')) == ty_double
	assert numeric_type(first_token('1.0f')) == ty_float
	// A hexadecimal float is at least a double, whatever it is written with.
	assert numeric_type(first_token('0x1.8p3')) == ty_double
}

fn test_a_hexadecimal_constant_without_a_suffix_may_be_unsigned() {
	// 0xFFFFFFFF does not fit an int, and C says such a constant has an unsigned type.
	t := first_token('0xFFFFFFFF')
	assert numeric_type(t) == ty_uint
}

fn test_numeric_suffix_is_found_by_difference_with_the_digit_run() {
	// Deriving the suffix this way means one rule decides where the digits stop, so the
	// suffix cannot disagree with the decoder.
	assert numeric_suffix('123u') == 'u'
	assert numeric_suffix('0x1Fu') == 'u'
	assert numeric_suffix('1.5f') == 'f'
	assert numeric_suffix('0x1F') == ''
}

fn test_string_literal_type_counts_the_terminator() {
	tok := first_token('"abc"')
	ty := string_literal_type(&tok)
	// Three characters plus the NUL.
	assert ty.array_len == 4
	assert ty.base == ty_char
	assert ty.size == 4
}

fn test_wide_string_literal_is_four_bytes_per_element() {
	tok := first_token('L"ab"')
	ty := string_literal_type(&tok)
	assert ty.base == ty_int
	assert ty.array_len == 3
	assert ty.size == 12
}

fn test_u8_prefixed_string_literal_is_a_byte() {
	tok := first_token('u8"ab"')
	assert string_element_type(&tok) == ty_char
}