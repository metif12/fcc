module backend

import src.ast

// The text-assembly backend.
//
// This is chibicc's `codegen.c` restricted to the half that does not need the
// expression and statement state machine: addressing, loads and stores, the
// conversion table, frame layout, and the data section. Function bodies are not
// generated yet and the entry point says so rather than emitting an empty
// prologue, because a `.s` file that assembles and returns garbage is worse than
// one that refuses.
//
// What is here is the part that can be checked on its own: a data section is
// either right or wrong, and `as` and the linker will say which.

// gp_max, fp_max, shadow_space, incoming_base, va_start_offset and va_slot live
// in src/ast/abi.v, and are used from there: the front end needs the frame
// arithmetic too and cannot import the backend without a cycle. Reading them
// rather than declaring them here is what makes the register counts the backend
// emits for and the frame sizes the front end lays out the same numbers by
// construction. These aliases exist so the rest of the backend reads as one name
// rather than `ast.` everywhere.
const gp_max = ast.gp_max
const fp_max = ast.fp_max
const shadow_space = ast.shadow_space
const incoming_base = ast.incoming_base
const va_slot = ast.va_slot
const va_start_offset = ast.va_start_offset

// arg_regs and its byte and word forms are the argument registers in Windows x64 order:
// `%rcx`, `%rdx`, `%r8`, `%r9`. A parameter is spilled from whichever form matches its
// width.
const arg_regs = ['%rcx', '%rdx', '%r8', '%r9']
const arg_regs8 = ['%cl', '%dl', '%r8b', '%r9b']
const arg_regs16 = ['%cx', '%dx', '%r8w', '%r9w']
const arg_regs32 = ['%ecx', '%edx', '%r8d', '%r9d']

// arg_regs_mirror is where a floating-point argument is *also* written when the callee is
// variadic.
//
// [MS x64 3.2] the caller must store the first four floating-point arguments into the
// integer registers, so that a callee that saves its register save area can find them
// without a fixed-point instruction. `printf("%d", 1.0)` depends on it. There is no
// counterpart for a non-variadic call, and gcc emits none for `dadd(1.0, 2.0)`.
const arg_regs_mirror = arg_regs

// TextEmitter writes AT&T assembly lines.
//
// It satisfies `Emit`, and that is the whole point of the interface: phase 3
// replaces this with an instruction encoder that satisfies the same interface,
// and nothing above it changes.
pub struct TextEmitter {
pub mut:
	lines []string
	// refs are the forward references a phase 3 backend would have to
	// backpatch. Assembly text names its labels rather than numbering them, so
	// there is nothing to record — but the interface says a backend may need to,
	// and a stub that lies would be found in phase 3 instead of here.
	refs []string
}

pub fn (mut e TextEmitter) text(line string) {
	e.lines << line
}

pub fn (mut e TextEmitter) bytes(data []u8) {
	e.lines << '// bytes() is not implemented by the text backend'
}

pub fn (mut e TextEmitter) patch_ref(from int, label string) {
	e.refs << '${from}: ${label}'
}

pub fn (mut e TextEmitter) label(name string) {
	e.lines << '${name}:'
}

pub fn (e &TextEmitter) text_of() string {
	return e.lines.join('\n') + '\n'
}

// AsmGen is the code generator.
pub struct AsmGen {
pub mut:
	out  []string
	emit &TextEmitter = &TextEmitter{}
	// depth counts 8-byte slots pushed since the frame was set up. It is what
	// tells the epilogue how far to move the stack pointer, so it is maintained
	// by every push and pop rather than recomputed.
	depth int
	// counter makes generated labels unique within one function.
	counter int
	// current_fn is the function being generated.
	current_fn &ast.Obj = unsafe { nil }
	// errors collects what could not be generated, rather than being reported as
	// it happens: a translation unit with several ungeneratable functions should
	// report all of them, not the first.
	errors []string
}

// gen is the entry point. It returns the assembly and the diagnostics.
pub fn (mut g AsmGen) gen(mut globals []&ast.Obj) (string, []string) {
	g.emit = &TextEmitter{}
	g.out = []

	g.line('  .file "vcc"')
	g.assign_lvar_offsets(mut globals)
	g.emit_data(globals)

	g.emit_text(globals)

	return g.emit.text_of(), g.errors
}

fn (mut g AsmGen) line(text string) {
	g.out << text
	g.emit.text(text)
}

// push and pop maintain `depth`, which is the epilogue's only input.
fn (mut g AsmGen) push() {
	g.line('  push %rax')
	g.depth++
}

fn (mut g AsmGen) pop(arg string) {
	g.line('  pop ${arg}')
	g.depth--
}

// align_to rounds n up to the nearest multiple of align.
pub fn align_to(n int, align int) int {
	if align <= 0 {
		return n
	}
	return (n + align - 1) / align * align
}

// reg_ax and reg_dx name the sub-register of an accumulator of a given width.
fn reg_ax(sz int) string {
	return match sz {
		1 { '%al' }
		2 { '%ax' }
		4 { '%eax' }
		else { '%rax' }
	}
}

fn reg_dx(sz int) string {
	return match sz {
		1 { '%dl' }
		2 { '%dx' }
		4 { '%edx' }
		else { '%rdx' }
	}
}

// gen_addr puts the absolute address of an lvalue in %rax.
//
// The distinction that matters throughout is that an expression's *value* and an
// expression's *address* are separate: an array's value is its address, which is
// where C's array-to-pointer decay happens, and a struct's value cannot be held in
// a register at all.
fn (mut g AsmGen) gen_addr(node &ast.Node) {
	match node.kind {
		.var_ref {
			obj := node.var
			// A variable-length array is always local, and its storage was
			// allocated at run time, so the frame slot holds a pointer to it.
			if obj.ty.kind == .vla {
				g.line('  mov ${obj.offset}(%rbp), %rax')
				return
			}
			if obj.is_local {
				g.line('  lea ${obj.offset}(%rbp), %rax')
				return
			}
			if obj.is_tls {
				// [ELF] A thread-local's address needs the offset from the thread
				// pointer. `mov %fs:0` is that pointer.
				g.line('  mov %fs:0, %rax')
				g.line('  add $${obj.name}@tpoff, %rax')
				return
			}
			// A function or a global: RIP-relative, because the absolute address
			// is not known at link time — the executable is loaded wherever the
			// loader puts it, and a shared object may be anywhere at all.
			g.line('  lea ${g.sym_operand(obj.name)}(%rip), %rax')
			return
		}
		.deref {
			g.gen_expr(node.lhs)
			return
		}
		.comma {
			// The value of a comma is its right operand, but its *address* is the
			// right operand's address, and the left operand still has to be
			// evaluated for its effects.
			g.gen_expr(node.lhs)
			g.gen_addr(node.rhs)
			return
		}
		.member {
			g.gen_addr(node.lhs)
			m := node.member or {
				g.errors << 'member access with no member at ${node.tok.line.disp_line}'
				return
			}
			if m.offset != 0 {
				g.line('  add $${m.offset}, %rax')
			}
			return
		}
		.vla_ptr {
			g.line('  lea ${node.var.offset}(%rbp), %rax')
			return
		}
		.funcall {
			// A call that returns a struct leaves the struct's address in a
			// buffer, and the call's value *is* that address.
			if node.ret_buffer != unsafe { nil } {
				g.gen_expr(node)
				return
			}
		}
		.assign, .cond_expr {
			// [C11 6.5.2.3p3] A struct-valued expression is not an lvalue, but an
			// assignment to one is allowed and copies. The backend treats the
			// assignment's own result as the address, which is what makes
			// `f().x` and `(a = b).x` work.
			if node.ty != unsafe { nil }
				&& (node.ty.kind == .struct_ || node.ty.kind == .union_) {
				g.gen_expr(node)
				return
			}
		}
		else {}
	}
	g.errors << 'not an lvalue line ' + node.tok.line.disp_line.str() + ' kind ' + int(node.kind).str() + ' ty ' + (if node.ty == unsafe { nil } {
		-1
	} else {
		int(node.ty.kind)
	}).str()
}

// load turns the address in %rax into the value it points at.
fn (mut g AsmGen) load(ty &ast.Type) {
	match ty.kind {
		.array, .struct_, .union_, .func, .vla {
			// An aggregate cannot be loaded into a register, so its "value" stays
			// as its address. This is the array decay, and it is why `a[i]` works
			// without a `&`.
			return
		}
		.basic {
			if ty.basic == .float_ {
				g.line('  movss (%rax), %xmm0')
				return
			}
			// A `long double` loads as a `double` — 8 bytes, measured against tcc.
			// The `fldt` that used to be here read ten bytes from an eight-byte
			// slot, taking the exponent from past its end.
			if ty.basic == .double_ || ty.basic == .ldouble_ {
				g.line('  movsd (%rax), %xmm0')
				return
			}
		}
		else {}
	}

	// A char or a short is always extended to the width of an int, so the lower
	// half of a register always holds a valid value and an `int` needs no
	// extension. An int is sign- or zero-extended to 64 bits so that arithmetic on
	// it can assume a clean register.
	insn := if ty.is_unsigned { 'movz' } else { 'movs' }
	if ty.size == 1 {
		g.line('  ${insn}bl (%rax), %eax')
	} else if ty.size == 2 {
		g.line('  ${insn}wl (%rax), %eax')
	} else if ty.size == 4 {
		g.line('  movsxd (%rax), %rax')
	} else {
		g.line('  mov (%rax), %rax')
	}
}

// store writes %rax through the address the stack top holds.
fn (mut g AsmGen) store(ty &ast.Type) {
	// `%rcx`, not `%rdi`. RDI is non-volatile on this target — Windows x64 keeps
	// RBX, RBP, RDI, RSI and R12-R15 across a call, where Linux keeps only RBX, RBP
	// and R12-R15 — so a callee that parks a live value in `%rdi` loses it to any
	// function that pops its store address there. The symptom lands in the caller,
	// not in the function that did it, which is what makes it hard to find: a
	// comparator written this way computes the right answer and then takes libc's
	// `qsort` down with it, because `qsort` held a value in `%rdi` across the call.
	g.pop('%rcx')
	match ty.kind {
		.struct_, .union_ {
			// A struct is copied a byte at a time. A `mov` of the whole thing
			// would need a size the assembler has to be told, and one byte per
			// store is what the reference does.
			for i in 0 .. ty.size {
				g.line('  mov ${i}(%rax), %r8b')
				g.line('  mov %r8b, ${i}(%rcx)')
			}
			return
		}
		.basic {
			if ty.basic == .float_ {
				g.line('  movss %xmm0, (%rcx)')
				return
			}
  if ty.basic == .double_ || ty.basic == .ldouble_ {
  // A `long double` stores as a `double` — 8 bytes. The `fstpt` that used to be
  // here popped the x87 stack, which held whatever was there rather than the
  // value in `%xmm0` that every other path in this generator produces.
  g.line('  movsd %xmm0, (%rcx)')
  return
  }
		}
		else {}
	}
	g.line('  mov ${reg_ax(ty.size)}, (%rcx)')
}

// cmp_zero compares the value against zero, for a condition.
//
// The integer and the floating cases are different instructions because the
// condition codes are set differently, and getting that wrong is the classic way
// to produce code that works for every value except the one it was tested with.
fn (mut g AsmGen) cmp_zero(ty &ast.Type) {
	match ty.kind {
		.basic {
			if ty.basic == .float_ {
				g.line('  xorps %xmm1, %xmm1')
				g.line('  ucomiss %xmm1, %xmm0')
				return
			}
  if ty.basic == .double_ || ty.basic == .ldouble_ {
  // A `long double` compares as a `double` — 8 bytes in `%xmm0`. The `fldz` /
  // `fucomip` sequence that used to be here compared the value against whatever
  // the x87 stack held, which was not it.
  g.line('  xorpd %xmm1, %xmm1')
  g.line('  ucomisd %xmm1, %xmm0')
  return
  }
		}
		else {}
	}
	if ty.size <= 4 {
		g.line('  cmp $0, %eax')
	} else {
		g.line('  cmp $0, %rax')
	}
}

// type_id is the conversion table's row and column index for a type.
const type_i8 = 0
const type_i16 = 1
const type_i32 = 2
const type_i64 = 3
const type_u8 = 4
const type_u16 = 5
const type_u32 = 6
const type_u64 = 7
  const type_f32 = 8
  const type_f64 = 9
  // There is no `type_f80`: a `long double` maps to `type_f64` in `type_id`,
  // because it is eight bytes on this target. The `f80` rows still present in
  // the tables below are unreachable through it.

fn type_id(ty &ast.Type) int {
	if ty.kind != .basic {
		// A pointer is the only thing that is not a basic type and still needs a
		// conversion row, and a pointer is eight bytes wide here.
		return type_u64
	}
	return match ty.basic {
		.char_ {
			if ty.is_unsigned { type_u8 } else { type_i8 }
		}
		.short_ {
			if ty.is_unsigned { type_u16 } else { type_i16 }
		}
		.int_, .enum_ {
			if ty.is_unsigned { type_u32 } else { type_i32 }
		}
		// On this target a long is 4 bytes, which is what the measured ABI says.
		.long_, .llong_ {
			if ty.is_unsigned { type_u64 } else { type_i64 }
		}
	.float_ { type_f32 }
	.double_, .ldouble_ { type_f64 }
		else { type_u64 }
	}
}

// cast emits the conversion between two types.
//
// A cast to void is not a conversion at all, and a cast to bool is a comparison
// rather than a move, which is why both leave before the table is consulted.
fn (mut g AsmGen) cast(from &ast.Type, to &ast.Type) {
	if to == unsafe { nil } || from == unsafe { nil } {
		return
	}
	if to.kind == .basic && to.basic == .void_ {
		return
	}
	if to.kind == .basic && to.basic == .bool_ {
		g.cmp_zero(from)
		g.line('  setne %al')
		g.line('  movzx %al, %eax')
		return
	}
	if insn := cast_insn(type_id(from), type_id(to)) {
		// The table holds whole instruction sequences for the conversions that
		// cannot be expressed as one instruction, notably the unsigned 64-bit to
		// floating ones, which need a branch. They are emitted as one line with
		// `;` separators, which the assembler accepts.
		g.line('  ${insn}')
	}
}

// cast_table holds one instruction sequence per ordered pair of types.
//
// A `none` is not a missing conversion but a decision: two types that need no
// instruction between them.
const cast_table = [
	['none', 'none', 'none', 'i32i64', 'i32u8', 'i32u16', 'none', 'i32i64', 'i32f32', 'i32f64',
		'i32f80']
	['i32i8', 'none', 'none', 'i32i64', 'i32u8', 'i32u16', 'none', 'i32i64', 'i32f32', 'i32f64',
		'i32f80']
	['i32i8', 'i32i16', 'none', 'i32i64', 'i32u8', 'i32u16', 'none', 'i32i64', 'i32f32', 'i32f64',
		'i32f80']
	['i32i8', 'i32i16', 'none', 'none', 'i32u8', 'i32u16', 'none', 'none', 'i64f32', 'i64f64',
		'i64f80']
	['i32i8', 'none', 'none', 'i32i64', 'none', 'none', 'none', 'i32i64', 'i32f32', 'i32f64', 'i32f80']
	['i32i8', 'i32i16', 'none', 'i32i64', 'i32u8', 'none', 'none', 'i32i64', 'i32f32', 'i32f64',
		'i32f80']
	['i32i8', 'i32i16', 'none', 'u32i64', 'i32u8', 'i32u16', 'none', 'u32i64', 'u32f32', 'u32f64',
		'u32f80']
	['i32i8', 'i32i16', 'none', 'none', 'i32u8', 'i32u16', 'none', 'none', 'u64f32', 'u64f64',
		'u64f80']
	['f32i8', 'f32i16', 'f32i32', 'f32i64', 'f32u8', 'f32u16', 'f32u32', 'f32u64', 'none', 'f32f64',
		'f32f80']
	['f64i8', 'f64i16', 'f64i32', 'f64i64', 'f64u8', 'f64u16', 'f64u32', 'f64u64', 'f64f32', 'none',
		'f64f80']
	['f80i8', 'f80i16', 'f80i32', 'f80i64', 'f80u8', 'f80u16', 'f80i32', 'f80i64', 'f80f32', 'f80f64',
		'none'],
]

const cast_instructions = {
	'i32i8':  'movsbl %al, %eax'
	'i32u8':  'movzbl %al, %eax'
	'i32i16': 'movswl %ax, %eax'
	'i32u16': 'movzwl %ax, %eax'
	'i32f32': 'cvtsi2ssl %eax, %xmm0'
	'i32i64': 'movsxd %eax, %rax'
	'i32f64': 'cvtsi2sdl %eax, %xmm0'
	'i32f80': 'mov %eax, -4(%rsp); fildl -4(%rsp)'
	'u32i64': 'mov %eax, %eax'
	'u32f32': 'mov %eax, %eax; cvtsi2ssq %rax, %xmm0'
	'u32f64': 'mov %eax, %eax; cvtsi2sdq %rax, %xmm0'
	'u32f80': 'mov %eax, %eax; mov %rax, -8(%rsp); fildll -8(%rsp)'
	'i64f32': 'cvtsi2ssq %rax, %xmm0'
	'i64f64': 'cvtsi2sdq %rax, %xmm0'
	'i64f80': 'movq %rax, -8(%rsp); fildll -8(%rsp)'
	// An unsigned 64-bit value above 2^63 is not representable by `cvtsi2sd`,
	// which reads the input as signed. The fix is to halve it and double the
	// result, which is exact for every value that is not representable, and the
	// branch is what keeps it exact for the ones that are.
	//
	// The slow path works in `%rcx`, not `%rdi`. This sequence is emitted as a
	// raw instruction line in the middle of an arbitrary expression, so whatever
	// it clobbers the caller loses — and `%rdi` is non-volatile on this target,
	// where Linux keeps only RBX, RBP and R12-R15. The register was chosen from
	// the same caller-saved scratch set `gen_asm` uses for inline-asm operands,
	// and it is free here: `%rax` holds the value being converted and `%xmm0` the
	// result, which is the whole of what lives at this point.
	'u64f32': 'cvtsi2ssq %rax, %xmm0'
	'u64f64': 'test %rax,%rax; js 1f; pxor %xmm0,%xmm0; cvtsi2sd %rax,%xmm0; jmp 2f; 1: mov %rax,%rcx; and $1,%eax; pxor %xmm0,%xmm0; shr %rcx; or %rax,%rcx; cvtsi2sd %rcx,%xmm0; addsd %xmm0,%xmm0; 2:'
	'u64f80': 'mov %rax, -8(%rsp); fildq -8(%rsp); test %rax, %rax; jns 1f; mov $1602224128, %eax; mov %eax, -4(%rsp); fadds -4(%rsp); 1:'
	'f32i8':  'cvttss2sil %xmm0, %eax; movsbl %al, %eax'
	'f32u8':  'cvttss2sil %xmm0, %eax; movzbl %al, %eax'
	'f32i16': 'cvttss2sil %xmm0, %eax; movswl %ax, %eax'
	'f32u16': 'cvttss2sil %xmm0, %eax; movzwl %ax, %eax'
	'f32i32': 'cvttss2sil %xmm0, %eax'
	'f32i64': 'cvttss2siq %xmm0, %rax'
	'f32u32': 'cvttss2siq %xmm0, %rax'
	'f32u64': 'cvttss2siq %xmm0, %rax'
	'f32f64': 'cvtss2sd %xmm0, %xmm0'
	'f32f80': 'movss %xmm0, -4(%rsp); flds -4(%rsp)'
	'f64i8':  'cvttsd2sil %xmm0, %eax; movsbl %al, %eax'
	'f64u8':  'cvttsd2sil %xmm0, %eax; movzbl %al, %eax'
	'f64i16': 'cvttsd2sil %xmm0, %eax; movswl %ax, %eax'
	'f64u16': 'cvttsd2sil %xmm0, %eax; movzwl %ax, %eax'
	'f64i32': 'cvttsd2sil %xmm0, %eax'
	'f64i64': 'cvttsd2siq %xmm0, %rax'
	'f64u32': 'cvttsd2siq %xmm0, %rax'
	'f64u64': 'cvttsd2siq %xmm0, %rax'
	'f64f32': 'cvtsd2ss %xmm0, %xmm0'
	'f64f80': 'movsd %xmm0, -8(%rsp); fldl -8(%rsp)'
	'f80i8':  'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistps -24(%rsp); fldcw -10(%rsp); movsbl -24(%rsp), %eax'
	'f80u8':  'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistps -24(%rsp); fldcw -10(%rsp); movzbl -24(%rsp), %eax'
	'f80i16': 'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistps -24(%rsp); fldcw -10(%rsp); movswl -24(%rsp), %eax'
	'f80u16': 'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistpl -24(%rsp); fldcw -10(%rsp); movzwl -24(%rsp), %eax'
	'f80i32': 'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistpl -24(%rsp); fldcw -10(%rsp); mov -24(%rsp), %eax'
	'f80i64': 'fnstcw -10(%rsp); movzwl -10(%rsp), %eax; or $12, %ah; mov %ax, -12(%rsp); fldcw -12(%rsp); fistpq -24(%rsp); fldcw -10(%rsp); mov -24(%rsp), %rax'
	'f80f32': 'fstps -8(%rsp); movss -8(%rsp), %xmm0'
	'f80f64': 'fstpl -8(%rsp); movsd -8(%rsp), %xmm0'
}

// cast_insn looks a conversion up, or returns none when the two types need no
// instruction between them.
fn cast_insn(from int, to int) ?string {
	if from < 0 || from >= cast_table.len || to < 0 || to >= cast_table[from].len {
		return none
	}
	name := cast_table[from][to]
	if name == 'none' {
		return none
	}
	return cast_instructions[name] or { name }
}

// has_flonum reports whether the bytes of a type in [lo, hi) are all
// floating-point, which is what decides whether a struct's first eight bytes go
// in an SSE register or a general-purpose one.
//
// The range is a byte range rather than a type test because the psABI's rule is
// about the bytes: a struct of two floats goes in one XMM register, and a struct
// of a float and an int does not.
pub fn has_flonum(ty &ast.Type, lo int, hi int, offset int) bool {
	if ty.kind == .struct_ || ty.kind == .union_ {
		for mem in ty.members {
			if !has_flonum(mem.ty, lo, hi, offset + mem.offset) {
				return false
			}
		}
		return true
	}
	if ty.kind == .array {
		for i in 0 .. ty.array_len {
			if !has_flonum(ty.base, lo, hi, offset + ty.base.size * i) {
				return false
			}
		}
		return true
	}
	// A byte outside the range being asked about is not evidence either way.
	// A `long double` member is floating-point — 8 bytes in `%xmm0` like a
	// `double` on this target. Leaving it out classified a struct holding one
	// as integer, so caller and callee disagreed about which register carried it.
	return offset < lo || hi <= offset || (ty.kind == .basic
		&& (ty.basic == .float_ || ty.basic == .double_ || ty.basic == .ldouble_))
}

// va_slots_for is how many eight-byte slots one argument occupies in the run a
// `va_list` walks.
//
// Everything is one slot: pointers, integers, floating-point values, `long double`,
// and an aggregate that is passed by reference. Only an aggregate of more than eight
// and up to sixteen bytes takes two, because [MS x64 2.2.5] passes that one by value
// in a pair of registers and the run has to hold both halves.
//
// A floating-point argument also takes an SSE register, which this does not count.
// That is not an omission: a variadic callee never reads `%xmm` through its
// `va_list`, because the caller mirrored the value into a general register. gcc's
// `movsd %xmm0, 32(%rsp)` for a *stack* floating-point argument is loading through
// `%xmm0` as scratch, not publishing the value there.
fn va_slots_for(ty &ast.Type) int {
	if (ty.kind == .struct_ || ty.kind == .union_) && ty.size > 8 && ty.size <= 16 {
		return 2
	}
	return 1
}

// assign_lvar_offsets gives every local a frame offset.
//
// A negative offset is a local: the frame grows downwards from %rbp. Parameters
// that arrived on the stack are positive and sit above the return address, and
// their offsets are decided by the caller, so the callee must agree with it.
fn (mut g AsmGen) assign_lvar_offsets(mut globals []&ast.Obj) {
	for gi in 0 .. globals.len {
		mut fun := globals[gi]
		if !fun.is_function {
			continue
		}
		// The first incoming stack parameter is at 48: the 8 bytes the `call` pushed as
		// the return address, the 8 bytes the prologue pushed to save the caller's `%rbp`,
		// and the callee's 32-byte home area above them.
		//
		// This was 40 for the whole of phase 2, and it was read off gcc's own output by
		// mistaking a *spilled register parameter* at `40(%rbp)` for the first stack
		// parameter — the callee also writes `%r9d` there, so the offset appears twice in
		// the listing and means two different things. Reading it as one thing put every
		// stack argument eight bytes low, which is why `f5(1,2,3,4,5)` returned 3: it
		// read the slot holding the third *register* argument.
		mut top := incoming_base
		mut bottom := 0
		mut gp := 0
		mut fp := 0
		// va_slots counts the eight-byte argument slots the *named* parameters occupy,
		// which is what tells `va_start` where the variadic ones begin. It is counted
		// here, inside the loop that already decides each parameter's register class,
		// because a second implementation of the calling convention is a second thing
		// that can disagree with the first.
		//
		// The rule is the Microsoft one and it is simpler than it looks: on a call to a
		// variadic function *every* argument takes a slot in the general-register run,
		// including a floating-point one, because the callee reads only that copy. A
		// floating-point argument also takes an SSE register, but that is not part of
		// the run `va_list` walks, so it does not move the count.
		//
		// Measured against gcc for `void two_dbl(int a, double b, double c, ...)`, where
		// `ap - &a` came out 24: `a`, `b` and `c` take three slots and the variadic
		// arguments start at the fourth.
		mut va_slots := 0

		for pi in 0 .. fun.params.len {
			ty := fun.params[pi].ty
			mut passed := false

			// A struct or union of at most two words goes in registers, and how many
			// of each kind depends on whether its first and second eight bytes are all
			// floating-point.
			if ty.kind == .struct_ || ty.kind == .union_ {
				if ty.size <= 16 {
					fp1 := has_flonum(ty, 0, 8, 0)
					fp2 := has_flonum(ty, 8, 16, 8)
					if fp + b2i(fp1) + b2i(fp2) < fp_max
						&& gp + b2i(!fp1) + b2i(!fp2) < gp_max {
						fp += b2i(fp1) + b2i(fp2)
						gp += b2i(!fp1) + b2i(!fp2)
						passed = true
					}
				}
			}

			// A pointer is passed like any other integer, so the test for "goes in a
			// general register" is "is not a floating-point value" rather than
			// "is a basic type". Getting that backwards puts every pointer parameter
			// on the stack at +16, where the caller never put it.
			//
			// A `long double` is a general-register argument too, and its register holds
			// an *address* rather than the value: [MS x64 2.2.5] passes anything wider
			// than eight bytes by reference. Listing it with the floating-point types is
			// what put it on the stack on the caller side as well, which is the other
			// half of why `sprintf(buf, "%Lf", x)` never worked.
	is_float := ty.kind == .basic
		&& (ty.basic == .float_ || ty.basic == .double_ || ty.basic == .ldouble_)
	if !passed && is_float && fp < fp_max {
		fp++
		passed = true
	}
	// A struct or union that reaches here did not fit in registers above —
	// either it is wider than sixteen bytes or the registers were already taken
	// — and it must go on the stack. Letting it fall into the general-register
	// path below gives it an in-frame slot and spills registers into it, while
	// the caller laid it out on the stack: the callee then reads registers for
	// a value that was never there, which is an access violation rather than a
	// wrong answer.
	if !passed && !is_float && ty.kind != .struct_ && ty.kind != .union_ && gp < gp_max {
		gp++
		passed = true
	}

			if passed {
				if fun.ty.is_variadic {
					va_slots += va_slots_for(ty)
				}
				continue
			}
			top = align_to(top, 8)
			fun.params[pi].offset = top
			top += ty.size
		}

		// A parameter that arrived on the stack is not in the register run at all: it
		// lives above `incoming_base`, past every home slot. So it does not advance
		// `va_slots`, and the count above is exactly "the named parameters that
		// arrived in registers" — which is what `leaq 24(%rbp)` is for a function with
		// one.
		if fun.ty.is_variadic {
			// `va_start_offset` is measured from `%rbp` to the first variadic slot. The
			// home area is *below* `incoming_base`, so a function with `va_slots` named
			// register parameters starts its walk at `va_start_offset + va_slots` slots —
			// which for the common `f(int n, ...)` is slot 1, at 24(%rbp).
			//
			// This was `va_slots` *below* the base at first, i.e. pointing into the
			// parameter's own home slot. That is one slot early, so the first `va_arg`
			// re-read the argument the `n` in `va_start(ap, n)` had already named, and
			// every later one was shifted. Measured: a probe reading six integers got
			// `1 9 17 25 33 41` instead of `1 2 3 4 5 6`, each eight bytes of drift per
			// step — which is what a walk that starts one slot too low and then steps
			// eight bytes looks like, because it is walking addresses rather than values.
			fun.va_start_offset = va_start_offset + va_slots * va_slot
		}

		for li in 0 .. fun.locals.len {
			// A positive offset means the caller already placed this object on the
			// stack, and the callee has to agree with it. Everything else gets a
			// negative one, which is why zero cannot be the "not yet placed" marker
			// chibicc uses: this project initialises an offset to -1.
			if fun.locals[li].offset > 0 {
				continue
			}
			mut align := fun.locals[li].align
			// [x86-64 psABI, p.14] An array of at least 16 bytes is aligned to 16
			// even when its element type asks for less.
			if fun.locals[li].ty.kind == .array && fun.locals[li].ty.size >= 16
				&& align < 16 {
				align = 16
			}
			if align < 1 {
				align = 1
			}
			bottom += fun.locals[li].ty.size
			bottom = align_to(bottom, align)
			fun.locals[li].offset = -bottom
		}

		fun.stack_size = align_to(bottom, 16)
	}
}

// emit_data writes every global with a definition.
fn (mut g AsmGen) emit_data(globals []&ast.Obj) {
	for obj in globals {
		if obj.is_function || !obj.is_definition {
			continue
		}
		// `.globl` is the only visibility directive that assembles on this target.
		// chibicc's `.local` and its `.type x, @object` are ELF spellings, and GNU as
		// rejects both here — "unknown pseudo-op: `.local'" and "junk at end of line"
		// pointing at the `,`. Measured here, not assumed. A symbol with no `.globl` is
		// already local.
		if !obj.is_static {
			g.line('  .globl ${obj.name}')
		}

		mut align := obj.align
		if obj.ty.kind == .array && obj.ty.size >= 16 && align < 16 {
			align = 16
		}
		if align < 1 {
			align = 1
		}

		if obj.is_tls {
			// [PE] A thread-local lives in `.tls$` and is reached through a two-byte
			// index into the TLS directory, which the object writer allocates. Nothing
			// here can invent that index, so it is reported rather than emitted wrongly.
			g.errors << 'thread-local "${obj.name}" needs the object writer: its section index is not allocated yet'
			continue
		}

		if obj.init_data.len > 0 {
			g.line('  .data')
			g.line('  .align ${align}')
			g.line('${obj.name}:')
			g.emit_bytes(obj)
			continue
		}

		g.line('  .bss')
		g.line('  .align ${align}')
		g.line('${obj.name}:')
		g.line('  .zero ${obj.ty.size}')
	}
}

// emit_bytes writes an object's byte image, turning each relocation into a quad
// of the symbol's address plus the offset.
//
// The bytes either side of a relocation are plain data, and a relocation is eight
// sym_operand spells a symbol for use *inside an instruction* or a relocation.
//
// GNU `as` reads `$` as the start of an immediate, so a name containing one has to be
// quoted there: `lea $$$(%rip), %rax` is `junk '(%rip)' after expression`, while
// `lea "$$$"(%rip), %rax` assembles, links and reads the right address. Measured here
// rather than assumed, because the failure is at assembly time and says nothing about
// which of the two spellings was meant.
//
// A label definition and `.globl` take the bare name — both accept it — so quoting is
// confined to the operand position where it is required.
fn (g &AsmGen) sym_operand(name string) string {
	if name.contains('$') {
		return '"${name}"'
	}
	return name
}

// emit_bytes writes an object's byte image, one `.byte` per byte unless a relocation
// falls in the range, and advances by the relocation's width rather than one byte.
fn (mut g AsmGen) emit_bytes(obj &ast.Obj) {
	mut pos := 0
	mut rel_i := 0
	rels := obj.rel
	for pos < obj.ty.size {
		if rel_i < rels.len && rels[rel_i].offset == pos {
			rel := rels[rel_i]
			g.line('  .quad ${g.sym_operand(rel.label)}${if rel.addend < 0 {
				rel.addend.str()
			} else {
				'+' + rel.addend.str()
			}}')
			rel_i++
			pos += 8
			continue
		}
		g.line('  .byte ${int(obj.init_data[pos])}')
		pos++
	}
}

// b2i is bool to int, for counting how many registers a parameter consumes.
fn b2i(b bool) int {
	return if b { 1 } else { 0 }
}
