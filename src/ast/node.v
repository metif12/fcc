module ast

// The AST node set. Names follow chibicc so the two implementations can be read
// side by side; a divergence in spelling is more expensive than a divergence in
// design.
//
// Only the declaration half of the parser is written, so most statement and
// expression kinds are declared but not yet produced. They are here rather than
// added later because `add_type` and the constant-expression evaluator switch
// over kinds they will meet only once the next slice lands, and because a node
// kind invented after the first code that switches on it is a kind the earlier
// code silently mishandles.

// Declared as a module-level `pub enum`, not `pub type ... = enum`, because that
// is the only form this V build accepts. See the note in token.v.
pub enum NodeKind {
	null_expr
	num
	var_ref
	add
	sub
	mul
	div
	mod
	// neg is unary minus. It is in this list rather than folded into `sub` with a
	// null right operand because a null operand is indistinguishable from an
	// uninitialised one, which is the mistake that produces silently wrong code.
	neg
	bit_and
	bit_or
	bit_xor
	shl
	shr
	eq
	ne
	lt
	le
	assign
	cond_expr
	comma
	member
	addr
	deref
	not
	bit_not
	log_and
	log_or
	return_
	if_
	for_
	do_
	switch_
	case_
	block_
	expr_stmt
	funcall
	num_stmt
	cast
	stmt_expr
	null_stmt
	// decl_stmt declares a variable and is always a statement.
	decl_stmt
	// compound_literal initialises an anonymous object, which V uses heavily for
	// `[]T{}` literals, so it is supported from the start rather than deferred.
	compound_literal
	// memzero clears a whole object. It exists because an initializer that fills
	// only some elements still has to zero the rest, and emitting one store per
	// element would be both larger and slower.
	memzero
	// vla_ptr reads the pointer a variable-length array was allocated into, which
	// is what addressing such an array goes through.
	vla_ptr
	// goto_ jumps to a label by name, goto_expr to a computed address, and label is
	// the definition a goto resolves to. They are three kinds rather than one with a
	// flag because the backend emits none, one and two instructions respectively, and
	// a flag would have to be tested before it knew which.
	goto_
	goto_expr
	label
	// generic covers a construct not yet modelled individually. It exists so the
	// parser can record what it saw and keep going instead of aborting, which is
	// what makes the corpus sweep in phase 1 possible at all.
	generic
}

// Obj is a named object: a variable, a function, or a string literal.
//
// `@[heap` for the same reason as Type: an object is referred to by pointer from
// the AST, and from a node's scope entry.
@[heap]
pub struct Obj {
pub mut:
	name     string
	ty       &Type = unsafe { nil }
	is_local bool
	// offset is the frame offset of a local, or -1 for something not yet placed.
	offset int = -1
	// stack_size is the frame size the backend reserved for a function, in bytes.
	// It is always a multiple of 16 so that the stack stays aligned across a call.
	stack_size int
	// align is the object's required alignment. It can exceed the type's, because
	// `_Alignas` and `__attribute__((aligned))` raise it.
	align int = -1
	// is_function marks an entry in the function namespace.
	is_function bool
	// is_definition is false for a declaration that has no body, and for a global
	// declared `extern`.
	is_definition bool
	// is_tentative marks a global with no initializer. C allows `int x;` at file
	// scope to define x as zero, and more than one of them is legal, so the
	// redundant ones are dropped once the whole file is read.
	is_tentative bool
	// is_static gives the object internal linkage. A file-scope `static` function
	// is also internal even though the C source says nothing about linkage on the
	// body.
	is_static bool
	// is_tls marks `__thread_local`, whose storage the object writer places apart.
	is_tls bool
	// line is where the object was declared, for diagnostics and `--dump-ast`.
	line int
	// init_data is the byte image of an initialized global.
	init_data []u8
	// rel lists the places in init_data that need a symbol address patched in.
	rel []Relocation
	// body is the function body, or empty for a variable. It is a slice of pointers
	// because a node is built and then referred to from the nodes around it, and a
	// value copy would silently lose a field written after the node was appended.
	//
	// The spelling is `[]&Node` and not `[]*Node` because this V build rejects a
	// `[]*T` struct field outright — "struct embedding must be declared at the
	// beginning of the struct body", pointing at the star. Measured with a two-struct
	// probe; `[]&T` in the same position is accepted.
	body []&Node
	// params and locals are in scope while the body is generated. They are slices of
	// pointers rather than of values, because an Obj is reached by pointer from the
	// nodes that name it, and because a value copy would silently lose a field
	// written after the object was appended.
	params []&Obj
	locals []&Obj
	// va_area is the register save area backing `va_start`, for a variadic
	// function. V calls variadic functions (`printf`), so this cannot be
	// deferred past phase 2.
	va_area &Obj = unsafe { nil }
	// alloca_bottom is the local holding the high-water mark of the stack a VLA has
	// claimed. The backend restores it on every return and on every `goto` out of a
	// block, which is the only way a VLA's storage ends when control leaves its scope.
	alloca_bottom &Obj = unsafe { nil }
	// body_start and body_end are the token indices of a function body's braces.
	// The declaration slice records the extent and does not parse what is inside,
	// so the next slice resumes from these rather than re-reading the file.
	body_start int = -1
	body_end   int = -1
}

// Node is one expression or statement.
//
// `@[heap` because a node is built and then referred to by pointer from every
// other node, from a type, and from the code generator.
@[heap]
pub struct Node {
pub mut:
	kind NodeKind
	ty   &Type = unsafe { nil }
	tok  Token

	// num is the value of a .num node, interpreted according to ty.
	num i64
	// fval is the value of a floating .num node. A literal carries one or the
	// other, never both, and ty says which.
	fval f64

	// var and member select what a .var_ref, .member or .compound_literal refers
	// to. `.var` is the base object; `.member` is the field within it.
	var    &Obj = unsafe { nil }
	member ?Member

	// lhs and rhs are the operands. The meaning of each position is fixed per
	// kind so that no node needs a variant per shape.
	lhs &Node = unsafe { nil }
	rhs &Node = unsafe { nil }

	// cond, then and els form a three-way conditional.
	cond &Node = unsafe { nil }
	then &Node = unsafe { nil }
	els  &Node = unsafe { nil }

	// body, init, inc and brk_label make up a loop: `for (init; cond; inc) body`.
	// brk_label and cont_label are already-unique names, resolved by the parser,
	// because a one-pass backend cannot invent them later.
	body       []&Node
	init       &Node = unsafe { nil }
	inc        &Node = unsafe { nil }
	brk_label  string
	cont_label string

	// cases and default_case make up a switch.
	cases        []&Node
	default_case &Node = unsafe { nil }

	// label_name and unique_label support `goto`; the parser resolves a forward
	// goto's label name at the point of definition and backpatches.
	label_name   string
	unique_label string

	// args is the argument list of a .funcall.
	args []&Node

	// func_ty is the resolved type of a .funcall target, needed to marshal
	// arguments per the ABI.
	func_ty &Type = unsafe { nil }

	// ret_buffer receives a struct returned by value, which on x86-64 is
	// returned in memory addressed through this hidden pointer.
	ret_buffer &Obj = unsafe { nil }

	// begin and end bound a case label's range. A single case has begin == end; a
	// GNU case 1 ... 5: has the two ends of its range.
	begin i64
	end   i64
}