module ast

// The shape of a C type, kept deliberately small in phase 1.
//
// This mirrors chibicc's `TypeKind` rather than inventing a V-flavoured
// hierarchy, because the point of the port is fidelity to a compiler that is
// known to handle real C. `basic` distinguishes signedness and width, which is
// the axis that decides the emitted instructions.

pub enum Basic {
	none
	void_
	_bool
	char_
	short_
	int_
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
pub struct Member {
pub mut:
	name string
	ty   &Type = unsafe { nil }
	// offset is the byte offset within the enclosing type.
	offset int
	// bit_width is 0 for a normal member, or the width of a bitfield.
	bit_width int
	// bit_offset is the bit position of a bitfield within its storage unit.
	bit_offset int
}

// Type describes one C type.
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
	// array_len is the element count for .array.
	array_len int = -1
	// vla_len is the run-time element count expression for .vla.
	vla_len &Node = unsafe { nil }
	// members are the fields of a .struct_ or .union_ type.
	members []Member
	// params and ret_type describe a .func type. A C function type is
	// `ret_type(params)`, so the return type lives here rather than in base.
	params   []Type
	ret_type &Type = unsafe { nil }
	// is_variadic is set for a C variadic function such as printf.
	is_variadic bool
	// name is the tag for a tagged type, for diagnostics.
	name string
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
