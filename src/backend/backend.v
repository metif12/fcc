module backend

// This module is the seam that makes the project affordable. The C front end
// never emits code; it drives an interface, and phase 2 (text assembly) and
// phase 3 (machine code plus an object writer) supply different implementations.
//
// The shape follows chibicc's `codegen.c`, which is the smallest complete
// description of what a C code generator must be told. The interface is
// deliberately concrete: every method is a thing a backend must actually emit,
// so an unimplemented one is a compile error rather than a silent gap.

import src.ast

// Emit is a sink for generated text or bytes.
//
// A phase 2 backend writes AT&T assembly lines. A phase 3 backend writes
// instruction bytes. Making the sink explicit is what allows one front end to
// drive both without knowing which is which.
pub interface Emit {
	// text appends one line of assembly.
	text(line string)
	// bytes appends raw encoded machine code, used only by the phase 3 backend.
	bytes(data []u8)
	// patch_ref records a forward reference to be resolved by the backend once
	// the label's address is known.
	patch_ref(from int, label string)
	// label emits a label definition at the current offset.
	label(name string)
}

// Backend generates code for a fully typed and checked AST.
//
// The front end guarantees that by the time any method is called, `ctx.node`
// refers to an expression whose type has been resolved, so a backend never needs
// to do type deduction — only emission.
pub interface Backend {
	// emit returns the sink the backend writes to. The front end calls it once.
	emit() Emit

	// --- unit level ---
	// begin_function opens a function body and reserves its stack frame.
	begin_function(ctx &Context)
	// end_function closes the body and restores the frame.
	end_function(ctx &Context)
	// declare_var allocates a local, or emits it into the data section when
	// `ctx.node` is at file scope.
	declare_var(ctx &Context)
	// emit_data writes an initialized global or string literal.
	emit_data(ctx &Context)

	// --- statements ---
	gen_stmt(ctx &Context)
	gen_expr(ctx &Context)

	// --- addressing ---
	// gen_addr computes the address of an lvalue and leaves it as the top value.
	gen_addr(ctx &Context)
	// load turns an address on the stack into the value it points at.
	load(ctx &Context)
	// store writes the top value through the address below it.
	store(ctx &Context)

	// --- value stack ---
	push() int
	pop(r int)
	// swap_exchange exchanges the top two stack entries; it exists because an
	// x86 backend can read a memory operand for one side of a comparison for
	// free, and paying for a spill instead is measurable.
	swap_exchange(op string)

	// --- calls ---
	// push_args evaluates arguments and marshals them per the target ABI.
	push_args(ctx &Context)
	// call emits the call itself; `ctx.fname` carries the resolved symbol.
	call(ctx &Context)
	// copy_ret moves a returned value into the caller's expected slot.
	copy_ret(ctx &Context)
	// copy_struct_reg copies a returned struct, which is ABI-defined rather than
	// type-defined and therefore needs the backend.
	copy_struct_reg(ctx &Context)

	// --- control flow ---
	// jump emits an unconditional jump to `label`.
	jump() string
	// label_jump defines a label and returns its name.
	label_jump() string
	// unique_label returns a label name not used elsewhere in this function.
	unique_label() string
	// lookup_jump finds `label`, returning None for a forward reference that has
	// not been defined yet. A one-pass backend therefore needs backpatching.
	lookup_jump(label string) ?string

	// --- frames ---
	// push_struct aligns and reserves `sz` bytes of frame, keeping the frame
	// 16-byte aligned as the x86-64 ABI requires.
	push_struct(sz int) int
	// push_local allocates `sz` bytes and returns the offset from `%rbp`.
	push_local(sz int) int
	// push_regs saves callee-saved registers the ABI requires.
	push_regs()
	// pop_regs restores them.
	pop_regs()
	// align_frame forces the current frame to `alignment`.
	align_frame(alignment int)
	// mark_local labels the last pushed local so a name can be attached to it.
	mark_local()
	// set_local_name attaches `name` to the most recently marked local.
	set_local_name(name string)

	// --- diagnostics ---
	// error reports a code generation failure at `ctx.node`'s position.
	error(msg string)
}

// Context is everything a backend method is allowed to know about the code
// being generated. It is passed by reference and mutated by both sides, which is
// what lets the front end push state (a pending expression) for the backend to
// consume.
pub struct Context {
pub mut:
	// node is the expression or statement currently being generated.
	node &ast.Node = unsafe { nil }
	// fname is the resolved symbol name for a call site.
	fname string
	// args is the marshalled argument list for the pending call.
	args []ast.Node
	// var_name is the identifier being declared, for diagnostics and `.name`.
	var_name string
	// tok is the token at the front of the stream, for error positions.
	tok ast.Token
	// func_ty is the type of the function being emitted, if any.
	func_ty &ast.Type = unsafe { nil }
}

// shared is the state every backend needs regardless of output format. It is
// held by pointer so the front end can hand the same instance to any backend.
pub struct Shared {
pub mut:
	// counter makes unique_label collision-free within one function.
	counter int
}
