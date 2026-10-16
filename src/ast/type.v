module ast

// The shape of a C type.
//
// This mirrors chibicc's `Type` rather than inventing a V-flavoured hierarchy,
// because the point of the port is fidelity to a compiler that is known to
// handle real C. `basic` distinguishes signedness and width, which is the axis
// that decides the emitted instructions.
//
// Sizes are not chibicc's. They were measured from the bundled tcc on
// x86-64 Windows, because vcc has to agree with the objects tcc already
// produced (`libgc.a`, `libtcc1.a`) and with V's own generated C. Two of them
// differ from chibicc: `long` is 4 bytes here, not 8, and `long double` is 8,
// not 16. Copying chibicc's table would have made every `long` in every V
// struct the wrong width, silently. See notes/DECISIONS.md D20.

pub enum Basic {
	none
	void_
	bool_
	char_
	short_
	int_
	// long_ and llong_ are distinct on this target: 4 and 8 bytes. They are one
	// type on System V, which is the ABI chibicc's table describes.
	long_
	llong_
	float_
	double_
	ldouble_
	enum_
}

// Kind of a type. `array` and `vla` are distinct because a VLA's length is only
// known at run time, which changes how the object is addressed.
pub enum TypeKind {
	basic
	pointer
	array
	vla
	func
	struct_
	union_
	enum_
}

// Member is one field of a struct or union.
//
// `@[heap` for the same reason as Type: members are held in a slice and reached by
// pointer from the initializer machinery.
@[heap]
pub struct Member {
pub mut:
	// The slice index of a member in `Type.members` is its ordinal, so no separate
	// `idx` field is kept: two ways to say the same thing would eventually disagree.
	name string
	ty   &Type = unsafe { nil }
	// offset is the byte offset within the enclosing type. For a bitfield it is
	// the start of the *storage unit*, which can be before the first bit the
	// field occupies; `bit_offset` says where in that unit the field starts.
	offset int
	// align is the field's required alignment, which `_Alignas` and
	// `__attribute__((aligned))` can raise above the type's own.
	align int
	// is_bitfield distinguishes the three states of a member: not a bitfield at all,
	// a bitfield of `bit_width` bits, or the zero-width bitfield that only pads. A
	// width of zero alone cannot tell them apart, because a plain `int` member also
	// has no width.
	is_bitfield bool
	// bit_width is the width of a bitfield in bits, or 0 when this is not one.
	bit_width int
	// bit_offset is the bit position of a bitfield within its storage unit.
	bit_offset int
}

// Relocation is a reference from a global's initial data to a symbol.
//
// A global can be initialised to a constant or to the address of another global;
// the latter cannot be known while parsing, so the byte image records a zero and
// the object writer patches it later.
@[heap]
pub struct Relocation {
pub mut:
	// offset is where in the initial data the value belongs.
	offset int
	// label is the symbol name, or the empty string when the value is a plain
	// constant. chibicc stores a `char **` here because the name is resolved
	// after the initializer is parsed; a V string is already immutable, so the
	// name is captured directly.
	label string
	// addend is the constant added to the symbol's address.
	addend i64
}

// Type describes one C type.
//
// `@[heap` because a type is reached through a pointer from everywhere else in the
// front end, and V's ownership checker refuses to store a reference that might
// point at a stack object unless the type is heap-allocated by contract. Every
// type here is created through `&ast.Type{}`, which is exactly that.
@[heap]
pub struct Type {
pub mut:
	kind TypeKind
	// base is the pointee/element/return type for pointer, array, vla and func.
	base &Type = unsafe { nil }
	// basic is meaningful when kind is .basic.
	basic Basic
	// size is the size in bytes, or -1 while it is not yet known.
	size int = -1
	// align is the required alignment in bytes, or -1 while not yet known.
	align int = -1
	// is_unsigned carries the signedness of a .basic type.
	is_unsigned bool
	// is_atomic marks `_Atomic T`. Nothing in vcc generates different code for
	// it yet; the flag exists so the parser can accept and record it.
	is_atomic bool
	// is_const and is_volatile mark a qualified type. They matter for exactly
	// one thing today: `_Generic` matches associations exactly, and a qualified
	// association never matches — so the parser records what it sees rather
	// than dropping it, and the generic selection strips the controlling
	// expression's qualifiers before comparing.
	is_const   bool
	is_volatile bool
	// is_signed marks an explicitly `signed` character type. Plain `char` and
	// `signed char` are the same representation on this target, but C11
	// 6.2.5p15 makes them distinct types and `_Generic` tells them apart: a
	// `const char *` controlling expression matches `const char *`, not
	// `const signed char *`. Nothing generates different code for them.
	is_signed bool
	// origin is the type this one was copied from. Type compatibility is decided
	// through it, which is what makes two spellings of the same typedef compare
	// equal without comparing their structure.
	origin &Type = unsafe { nil }
	// array_len is the element count for .array, or -1 when it is unknown.
	array_len int = -1
	// vla_len is the run-time element count expression for .vla.
	vla_len &Node = unsafe { nil }
	// vla_size names the local that holds the byte size of a .vla, which
	// `sizeof` needs at run time.
	vla_size &Obj = unsafe { nil }
	// members are the fields of a .struct_ or .union_ type.
	members []Member
	// is_flexible marks a struct whose last member is an array of unknown size.
	is_flexible bool
	// pack is the maximum alignment a member may be given, from `#pragma pack(N)`
	// or from `__attribute__((packed))` which is the same as pack(1). Zero means no
	// packing is in effect.
	pack int
	// params and ret_type describe a .func type. A C function type is
	// `ret_type(params)`, so the return type lives here rather than in base.
	// A null parameter list means variadic, which is C's rule for `(void)` spelled
	// as an empty list; an explicitly empty list is not variadic.
	params   []&Type
	ret_type &Type = unsafe { nil }
	// is_variadic marks a C variadic function such as printf.
	is_variadic bool
	// name is the name the declarator that produced this type introduced.
	name string
	// tag is the struct, union or enum tag, which is a different thing from the
	// declarator's name: `struct S s;` gives one type both, and the variable's own
	// type carries `s` where the tag `S` belongs. chibicc keeps both in `name` and
	// lets the last writer win, so `struct S s;` prints as `struct s`.
	tag string
	// name_line is the line the name was declared on, which is what a diagnostic
	// about a missing or duplicated name needs. A whole token per type would be
	// about a hundred bytes of dead weight to carry an integer.
	name_line int
}

// size_or_known returns the size, treating -1 as "not computed yet" rather than
// as a size of zero. A zero-size type is a real thing in C (`struct {}` in GCC),
// so the two states must not be conflated.
pub fn (t &Type) size_or_known() ?int {
	if t.size < 0 {
		return none
	}
	return t.size
}

// is_complete reports whether the type has a known size, which is what deciding
// whether a declaration is legal comes down to.
pub fn (t &Type) is_complete() bool {
	return t.size >= 0
}