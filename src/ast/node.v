module ast

// The AST node set, restricted to what phase 1 needs in order to parse V's
// generated C. Names follow chibicc so the two implementations can be read side
// by side; a divergence in spelling is more expensive than a divergence in
// design.

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
	// generic covers a construct not yet modelled individually. It exists so the
	// parser can record what it saw and keep going instead of aborting, which is
	// what makes the corpus sweep in phase 1 possible at all.
	generic
}

// Obj is a named object: a variable, a function, or a string literal.
pub struct Obj {
pub mut:
	name     string
	ty       &Type = unsafe { nil }
	is_local bool
	// offset is the frame offset of a local, or -1 for something not yet placed.
	offset int = -1
	// is_function marks an entry in the function namespace.
	is_function bool
	// is_definition is false for a declaration that has no body.
	is_definition bool
	// init_data is the byte image of an initialized global.
	init_data []u8
	// body is the function body, or empty for a variable.
	body []Node
	// params and locals are in scope while the body is generated.
	params []Obj
	locals []Obj
	// va_area is the register save area backing `va_start`, for a variadic
	// function. V calls variadic functions (`printf`), so this cannot be
	// deferred past phase 2.
	va_area &Obj = unsafe { nil }
}

// Node is one expression or statement.
pub struct Node {
pub mut:
	kind NodeKind
	ty   &Type = unsafe { nil }
	tok  Token

	// num is the value of a .num node, interpreted according to ty.
	num i64

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
	body       []Node
	init       &Node = unsafe { nil }
	inc        &Node = unsafe { nil }
	brk_label  string
	cont_label string

	// cases and default_case make up a switch.
	cases        []Node
	default_case &Node = unsafe { nil }

	// label_name and unique_label support `goto`; the parser resolves a forward
	// goto's label name at the point of definition and backpatches.
	label_name   string
	unique_label string

	// args is the argument list of a .funcall.
	args []Node

	// func_ty is the resolved type of a .funcall target, needed to marshal
	// arguments per the ABI.
	func_ty &Type = unsafe { nil }

	// ret_buffer receives a struct returned by value, which on x86-64 is
	// returned in memory addressed through this hidden pointer.
	ret_buffer &Obj = unsafe { nil }
}
