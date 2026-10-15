module backend

import src.ast

// The expression and statement walk.
//
// This is the other half of chibicc's `codegen.c`: a stack machine over one
// accumulator, with `depth` counting the eight-byte slots that have been pushed.
// It is a separate file from `asm.v` because that one is about where things live
// in the object and this one is about the order of the instructions.

// arg_class is how one argument will be passed, decided once per call site.
//
// chibicc marks the argument node itself with `pass_by_stack`, which means the
// classification is written into the AST and read back twice. It is computed into
// this instead, because the AST is shared and a second code generator over the
// same tree would inherit the first one's decisions.
struct ArgClass {
mut:
	by_stack     bool
	is_aggregate bool
	// fp1 and fp2 are whether the first and second eight bytes of an aggregate are
	// all floating-point, which decides XMM versus a general register.
	fp1 bool
	fp2 bool
}

// classify_args walks a call's arguments and decides each one's register class.
//
// It returns how many eight-byte slots go on the stack and the classification
// itself, because the caller loads the registers and the callee has to be told the
// same thing.
fn (mut g AsmGen) classify_args(node &ast.Node) (int, []ArgClass) {
	mut stack := 0
	mut gp := 0
	mut fp := 0
	mut classes := []ArgClass{}

	// A struct larger than two words is returned in memory, and the caller passes a
	// pointer to that buffer as if it were the first argument.
	if node.ret_buffer != unsafe { nil } && node.ty.size > 16 {
		gp++
	}

	for arg in node.args {
		ty := arg.ty
		mut c := ArgClass{}
		if ty.kind == .struct_ || ty.kind == .union_ {
			c.is_aggregate = true
			if ty.size > 16 {
				c.by_stack = true
				stack += align_to(ty.size, 8) / 8
			} else {
				c.fp1 = has_flonum(ty, 0, 8, 0)
				c.fp2 = has_flonum(ty, 8, 16, 0)
				// The registers have to be checked against the *cumulative* count, so a
				// struct that would fit on its own can still not fit once the arguments
				// before it have taken theirs.
				if fp + b2i(c.fp1) + b2i(c.fp2) < fp_max
					&& gp + b2i(!c.fp1) + b2i(!c.fp2) < gp_max {
					fp += b2i(c.fp1) + b2i(c.fp2)
					gp += b2i(!c.fp1) + b2i(!c.fp2)
				} else {
					c.by_stack = true
					stack += align_to(ty.size, 8) / 8
				}
			}
		} else if ty.kind == .basic {
			if ty.basic == .float_ || ty.basic == .double_ {
				// [MS x64 3.2] A floating-point argument to a *variadic* function is
				// passed in an SSE register **and** in the general register that its
				// position among all the arguments selects, because the callee's variadic
				// walk only ever reads the general-register copy. So it consumes a general
				// position as well, and once those are gone it goes on the stack even
				// though `%xmm` registers are still free.
				//
				// This is measured: for `printf("d=%g s=%s i=%d f=%g\n", 1.5, "hi", 7, 2.5)`
				// gcc puts the format string in `%rcx`, 1.5 in `%xmm1` *and* `%rdx`,
				// `"hi"` in `%r8`, 7 in `%r9`, and 2.5 in `%xmm0` *and* `32(%rsp)`.
				if node.func_ty != unsafe { nil } && node.func_ty.is_variadic {
					if gp >= gp_max {
						c.by_stack = true
						stack++
					}
					gp++
				}
				if fp >= fp_max {
					c.by_stack = true
					stack++
				}
				fp++
			} else if ty.basic == .ldouble_ {
				// [MS x64 2.2.5] An argument larger than eight bytes that is not a
				// structure is passed by *reference*: the caller spills it and puts the
				// address in the next integer register. x87 has no register class here
				// either, and the psABI's two-stack-slot x87 argument does not exist on
				// this target — gcc does `fstpt` to its own frame and `movq` the address.
				//
				// So it is classified exactly like a pointer: one general register, whose
				// value is an address. `push_args_pass` spills the value and pushes that
				// address, which is what makes the ordinary `pop arg_regs[gp]` below load
				// it.
				if gp >= gp_max {
					c.by_stack = true
					stack++
				}
				gp++
			} else {
				if gp >= gp_max {
					c.by_stack = true
					stack++
				}
				gp++
			}
		} else {
			if gp >= gp_max {
				c.by_stack = true
				stack++
			}
			gp++
		}
		classes << c
	}
	return stack, classes
}

// push_struct copies an aggregate onto the stack, eight bytes at a time.
fn (mut g AsmGen) push_struct(ty &ast.Type) {
	sz := align_to(ty.size, 8)
	g.line('  sub $${sz}, %rsp')
	g.depth += sz / 8
	for i in 0 .. ty.size {
		g.line('  mov ${i}(%rax), %r10b')
		g.line('  mov %r10b, ${i}(%rsp)')
	}
}

// pushf and popf move an SSE value between %xmm0 and the stack.
//
// Every stack slot is eight bytes whatever it holds, which is why nothing here is
// scaled by the value's width.
fn (mut g AsmGen) pushf() {
	g.line('  sub $8, %rsp')
	g.line('  movsd %xmm0, (%rsp)')
	g.depth++
}

fn (mut g AsmGen) popf(reg int) {
	g.line('  movsd (%rsp), %xmm${reg}')
	g.line('  add $8, %rsp')
	g.depth--
}

// push_args evaluates a call's arguments onto the stack in two passes.
//
// The first pass pushes only the arguments that go in registers and the second
// only the ones that go on the stack, because the two have to end up in opposite
// parts of the frame and evaluating them in one pass would interleave them.
fn (mut g AsmGen) push_args(node &ast.Node, classes []ArgClass) int {
	mut total := 0
	for i, c in classes {
		if !c.by_stack {
			continue
		}
		// The argument area is counted in eight-byte slots, not in arguments: a
		// `long double` is pushed as two of them (`sub $16, %rsp; fstpt (%rsp)`), and an
		// aggregate larger than two eightbytes is pushed by `push_struct`, which reserves
		// its whole size. Counting one slot for either made the caller's own cleanup short
		// by the difference — `sprintf(buf, "%Lf", x)` left one value on the stack, and
		// passing a 32-byte struct left three.
		ty := node.args[i].ty
		if ty.kind == .basic && ty.basic == .ldouble_ {
			total += 2
		} else if ty.kind == .struct_ || ty.kind == .union_ {
			total += align_to(ty.size, 8) / 8
		} else {
			total++
		}
	}
	// [psABI] The argument area must end 16-byte aligned, so an odd number of
	// eight-byte slots gets a padding slot.
	//
	// It goes *below* the argument area, which for a sequence of `push`es means
	// emitted first: a `push` decrements `%rsp`, so whatever is reserved first ends up
	// at the lowest address, and the callee reads the first stack argument from the
	// lowest address of the area. Measured from gcc's own `probe(6, 1, 2, 3, 4, 5, 6)`:
	// it pads with `subq $64` and writes the three stack arguments at 32, 40 and
	// 48(%rsp) — padding above the arguments, above 48 — which is the same slot from
	// the other side, because gcc reserves downward and pushes upward while this
	// generator does the reverse.
	if (g.depth + total) % 2 == 1 {
		g.line('  sub $8, %rsp')
		g.depth++
		total++
	}

	g.push_args_pass(node, classes, true)
	g.push_args_pass(node, classes, false)

	if node.ret_buffer != unsafe { nil } && node.ty.size > 16 {
		g.line('  lea ${node.ret_buffer.offset}(%rbp), %rax')
		g.push()
	}
	return total
}

fn (mut g AsmGen) push_args_pass(node &ast.Node, classes []ArgClass, first_pass bool) {
	// A `push` decrements `%rsp`, so the last thing pushed is at the lowest address, and
	// the first stack argument has to be at the lowest address — that is where the callee
	// reads it from. So *both* kinds of argument are pushed right to left, and the
	// register arguments go last so that they end up on top, in the reverse order the
	// pops need.
	//
	// Reversing only the stack arguments looks tempting and is wrong: a six-argument call
	// then reads `x=1=2=3=5=4` instead of `x=1=2=3=4=5`, which is the swap this comment
	// exists to prevent.
	mut i := node.args.len - 1
	for i >= 0 {
		// Push the arguments this pass is for, and skip the rest.
		//
		// The condition used to *skip* `by_stack == first_pass`, which meant the pass
		// named `true` pushed the arguments that were **not** on the stack. So the
		// register arguments went on first and the stack arguments last — and since a
		// `push` decrements `%rsp`, "last" is the *lowest* address, which put the first
		// stack argument at the bottom of the argument area, underneath the home area,
		// instead of at the top of it. The callee then read whatever was eight bytes
		// higher: `f5(1,2,3,4,5)` returned 4, the fourth register argument.
		if classes[i].by_stack != first_pass {
			i--
			continue
		}
		g.push_one(node.args[i])
		i--
	}
}

// push_one puts one argument's value onto the stack in the form the callee expects to
// find it: an aggregate copied out of `%rax`, an SSE value in `%xmm0`, a `long double`
// spilled with its address left on top, and everything else as a word in `%rax`.
fn (mut g AsmGen) push_one(arg &ast.Node) {
	g.gen_expr(arg)
	ty := arg.ty
	if ty.kind == .struct_ || ty.kind == .union_ {
		g.push_struct(ty)
	} else if ty.kind == .basic && (ty.basic == .float_ || ty.basic == .double_) {
		g.pushf()
	} else if ty.kind == .basic && ty.basic == .ldouble_ {
		// Spill the value where it will survive the call, then push its *address* so
		// the rest of the machinery treats it as the pointer-sized argument it now is.
		// The 16 bytes stay on the stack until the call returns, which is exactly the
		// window the callee has to read them.
		g.line('  sub $16, %rsp')
		g.line('  fstpt (%rsp)')
		g.depth += 2
		g.line('  mov %rsp, %rax')
		g.push()
	} else {
		g.push()
	}
}

// copy_ret_buffer stores a returned aggregate into the caller's buffer.
//
// The first eight bytes come back in %rax or %xmm0 and the second eight in %rdx or
// %xmm1, decided by the same byte test that decided where they were passed.
fn (mut g AsmGen) copy_ret_buffer(var &ast.Obj) {
	ty := var.ty
	mut gp := 0
	mut fp := 0

	if has_flonum(ty, 0, 8, 0) {
		if ty.size == 4 {
			g.line('  movss %xmm0, ${var.offset}(%rbp)')
		} else {
			g.line('  movsd %xmm0, ${var.offset}(%rbp)')
		}
		fp++
	} else {
		// The bytes arrive with the first in %al, so they are stored one at a time
		// from the bottom up and %rax is shifted down after each.
		for i in 0 .. imin(8, ty.size) {
			g.line('  mov %al, ${var.offset + i}(%rbp)')
			g.line('  shr $8, %rax')
		}
		gp++
	}

	if ty.size > 8 {
		if has_flonum(ty, 8, 16, 0) {
			if ty.size == 12 {
				g.line('  movss %xmm${fp}, ${var.offset + 8}(%rbp)')
			} else {
				g.line('  movsd %xmm${fp}, ${var.offset + 8}(%rbp)')
			}
		} else {
			r1 := if gp == 0 { '%al' } else { '%dl' }
			r2 := if gp == 0 { '%rax' } else { '%rdx' }
			for i in 8 .. imin(16, ty.size) {
				g.line('  mov ${r1}, ${var.offset + i}(%rbp)')
				g.line('  shr $8, ${r2}')
			}
		}
	}
}

// copy_struct_reg loads a returned aggregate out of the buffer the caller passed.
//
// [C11 5.1.2.3] An aggregate of at most two words comes back in registers; the
// callee puts it there, and the byte test decides which.
fn (mut g AsmGen) copy_struct_reg() {
	ty := g.return_type()
	mut gp := 0
	mut fp := 0
	// The hidden buffer's address goes in a volatile register: `%rdi` is
	// non-volatile on this target, and this runs in the caller immediately after a
	// call, so the caller's own `%rdi` still has to be intact when this returns.
	g.line('  mov %rax, %rcx')

	if has_flonum(ty, 0, 8, 0) {
		if ty.size == 4 {
			g.line('  movss (%rcx), %xmm0')
		} else {
			g.line('  movsd (%rcx), %xmm0')
		}
		fp++
	} else {
		g.line('  mov $0, %rax')
		// Backwards, shifting left: the last byte has to end up highest.
		mut i := imin(8, ty.size) - 1
		for i >= 0 {
			g.line('  shl $8, %rax')
			g.line('  mov ${i}(%rcx), %al')
			i--
		}
		gp++
	}

	if ty.size > 8 {
		if has_flonum(ty, 8, 16, 0) {
			if ty.size == 4 {
				g.line('  movss 8(%rcx), %xmm${fp}')
			} else {
				g.line('  movsd 8(%rcx), %xmm${fp}')
			}
		} else {
			r1 := if gp == 0 { '%al' } else { '%dl' }
			r2 := if gp == 0 { '%rax' } else { '%rdx' }
			g.line('  mov $0, ${r2}')
			mut i := imin(16, ty.size) - 1
			for i >= 8 {
				g.line('  shl $8, ${r2}')
				g.line('  mov ${i}(%rcx), ${r1}')
				i--
			}
		}
	}
}

// copy_struct_mem copies a returned aggregate into the hidden buffer that arrived
// as the first argument.
fn (mut g AsmGen) copy_struct_mem() {
	ty := g.return_type()
	// `%rcx` for the destination, not `%rdi`: the destination register has to be
	// one the caller can lose, and `%rdi` is not one on Windows x64.
	g.line('  mov ${g.current_fn.params[0].offset}(%rbp), %rcx')
	for i in 0 .. ty.size {
		g.line('  mov ${i}(%rax), %dl')
		g.line('  mov %dl, ${i}(%rcx)')
	}
}

// builtin_alloca carves space out of the stack for a variable-length array.
//
// A VLA's extent is not known until run time, so the allocation is a runtime
// operation: the temporary area already used above %rsp is shifted up by the
// requested size and the high-water mark moves with it, so that a `return` can
// give the space back.
fn (mut g AsmGen) builtin_alloca() {
	// `%r11`, not `%rdi`, for the rounded size. `%rdi` is non-volatile on this
	// target, so using it here would destroy a value the caller's own caller was
	// promised it could rely on. `%r11` is in the same caller-saved scratch set
	// `gen_asm` uses, and nothing else in this routine touches it: `%rcx` is the
	// copy count, `%rdx` the destination and `%rax` the source.
	g.line('  add $15, %r11')
	g.line('  and $0xfffffff0, %r11d')

	bottom := g.current_fn.alloca_bottom.offset
	g.line('  mov ${bottom}(%rbp), %rcx')
	g.line('  sub %rsp, %rcx')
	g.line('  mov %rsp, %rax')
	g.line('  sub %r11, %rsp')
	g.line('  mov %rsp, %rdx')
	g.line('1:')
	g.line('  cmp $0, %rcx')
	g.line('  je 2f')
	g.line('  mov (%rax), %r8b')
	g.line('  mov %r8b, (%rdx)')
	g.line('  inc %rdx')
	g.line('  inc %rax')
	g.line('  dec %rcx')
	g.line('  jmp 1b')
	g.line('2:')

	g.line('  mov ${bottom}(%rbp), %rax')
	g.line('  sub %r11, %rax')
	g.line('  mov %rax, ${bottom}(%rbp)')
}

// store_fp and store_gp spill an incoming argument register to its frame slot.
fn (mut g AsmGen) store_fp(r int, offset int, sz int) {
	if sz == 4 {
		g.line('  movss %xmm${r}, ${offset}(%rbp)')
	} else {
		g.line('  movsd %xmm${r}, ${offset}(%rbp)')
	}
}

fn (mut g AsmGen) store_gp(r int, offset int, sz int) {
	if sz == 1 {
		g.line('  mov ${arg_regs8[r]}, ${offset}(%rbp)')
	} else if sz == 2 {
		g.line('  mov ${arg_regs16[r]}, ${offset}(%rbp)')
	} else if sz == 4 {
		g.line('  mov ${arg_regs32[r]}, ${offset}(%rbp)')
	} else if sz == 8 {
		g.line('  mov ${arg_regs[r]}, ${offset}(%rbp)')
	} else {
		// A width that is not 1, 2, 4 or 8 is an aggregate, and its bytes come out of
		// the register least significant first.
		for i in 0 .. sz {
			g.line('  mov ${arg_regs8[r]}, ${offset + i}(%rbp)')
			g.line('  shr $8, ${arg_regs[r]}')
		}
	}
}

// return_type is the declared result type of the function being emitted.
fn (g &AsmGen) return_type() &ast.Type {
	if g.current_fn == unsafe { nil } || g.current_fn.ty == unsafe { nil } {
		return unsafe { nil }
	}
	return g.current_fn.ty.ret_type
}

// imin is the integer minimum, which C spells as a macro.
fn imin(a int, b int) int {
	return if a < b { a } else { b }
}

// next_label returns a number no other generated label in this file uses.
fn (mut g AsmGen) next_label() int {
	g.counter++
	return g.counter
}

// gen_expr puts an expression's value in %rax, or %xmm0 for a floating one.
fn (mut g AsmGen) gen_expr(node &ast.Node) {
	if node == unsafe { nil } {
		return
	}
	match node.kind {
		.null_expr, .null_stmt { return }
		.num {
			g.gen_num(node)
			return
		}
		.neg {
			g.gen_expr(node.lhs)
			g.gen_neg(node.ty)
			return
		}
		.var_ref {
			g.gen_addr(node)
			g.load(node.ty)
			return
		}
		.vla_ptr {
			g.gen_addr(node)
			g.load(node.ty)
			return
		}
		.va_arg_ {
			g.gen_va_arg(node)
			return
		}
		.va_start_ {
			// Unreachable from `gen_expr`: `va_start` is parsed as a statement, so
			// `gen_stmt` handles it. It is here so that reaching it is a diagnostic about
			// the node's kind rather than a silently missing store.
			g.errors << 'va_start is a statement; it was reached as an expression'
			return
		}
		.member {
			g.gen_addr(node)
			g.load(node.ty)
			g.gen_bitfield_extract(node)
			return
		}
		.deref {
			g.gen_expr(node.lhs)
			g.load(node.ty)
			return
		}
		.addr {
			g.gen_addr(node.lhs)
			return
		}
		.assign {
			g.gen_assign(node)
			return
		}
		.stmt_expr {
			for s in node.body {
				g.gen_stmt(s)
			}
			return
		}
		.comma {
			g.gen_expr(node.lhs)
			g.gen_expr(node.rhs)
			return
		}
		.cast {
			g.gen_expr(node.lhs)
			g.cast(node.lhs.ty, node.ty)
			return
		}
		.memzero {
			// `rep stosb` takes its destination only in `%rdi` — that is the
			// instruction, not a choice — and `%rdi` is non-volatile on this target, so
			// the caller's own copy is saved and restored around the four instructions
			// this needs. The alternative, a byte-at-a-time loop into a volatile
			// register, would work and would be slower for every aggregate local.
			g.line('  push %rdi')
			g.line('  mov $${node.var.ty.size}, %rcx')
			g.line('  lea ${node.var.offset}(%rbp), %rdi')
			g.line('  mov $0, %al')
			g.line('  rep stosb')
			g.line('  pop %rdi')
			return
		}
		.cond_expr {
			c := g.next_label()
			g.gen_expr(node.cond)
			g.cmp_zero(node.cond.ty)
			g.line('  je .L.else.${c}')
			// The GNU `a ?: b` has no middle operand: `a` is evaluated once and its
			// value is the result when it is nonzero. Generating the branch again would
			// evaluate `a` twice, which is observable — `++i ?: 10` increments twice and
			// answers 5 where the answer is 4. The value is already in %rax from the test
			// above, so the branch is already taken.
			if !node.then_is_cond {
				g.gen_expr(node.then)
			}
			g.line('  jmp .L.end.${c}')
			g.line('.L.else.${c}:')
			g.gen_expr(node.els)
			g.line('.L.end.${c}:')
			return
		}
		.not {
			g.gen_expr(node.lhs)
			g.cmp_zero(node.lhs.ty)
			g.line('  sete %al')
			g.line('  movzx %al, %rax')
			return
		}
		.bit_not {
			g.gen_expr(node.lhs)
			g.line('  not %rax')
			return
		}
		.log_and {
			c := g.next_label()
			g.gen_expr(node.lhs)
			g.cmp_zero(node.lhs.ty)
			g.line('  je .L.false.${c}')
			g.gen_expr(node.rhs)
			g.cmp_zero(node.rhs.ty)
			g.line('  je .L.false.${c}')
			g.line('  mov $1, %rax')
			g.line('  jmp .L.end.${c}')
			g.line('.L.false.${c}:')
			g.line('  mov $0, %rax')
			g.line('.L.end.${c}:')
			return
		}
		.log_or {
			c := g.next_label()
			g.gen_expr(node.lhs)
			g.cmp_zero(node.lhs.ty)
			g.line('  jne .L.true.${c}')
			g.gen_expr(node.rhs)
			g.cmp_zero(node.rhs.ty)
			g.line('  jne .L.true.${c}')
			g.line('  mov $0, %rax')
			g.line('  jmp .L.end.${c}')
			g.line('.L.true.${c}:')
			g.line('  mov $1, %rax')
			g.line('.L.end.${c}:')
			return
		}
		.funcall {
			g.gen_funcall(node)
			return
		}
		.goto_expr, .label {
			// [GNU] A label's address is RIP-relative to itself.
			g.line('  lea ${node.unique_label}(%rip), %rax')
			return
		}
		else {}
	}
	g.gen_binary(node)
}

// f32_bits and f64_bits are a float's IEEE-754 representation.
//
// The conversion has to be a reinterpretation and not a numeric one. V's `u64(f)`
// converts the *value*, so `u64(2.0f32)` is 2 — and `mov $2, %rax` for the literal
// `2.0f` loads the integer two into %xmm0, which is right for every test that does
// not compare the value against a real 2.0f. That is the failure mode this project
// can least afford in a code generator.
fn f32_bits(val f32) u64 {
	return u64(unsafe { *(&u32(&val)) })
}

fn f64_bits(val f64) u64 {
	return unsafe { *(&u64(&val)) }
}

// gen_num loads a literal.
//
// A floating literal is loaded by its bit pattern, because no instruction puts
// 3.14 into %xmm0. The literal's own type is what decides which, so a node with no
// type yet is reported rather than loaded as an integer — `mov $2` for `2.0f` is the
// kind of silently wrong instruction this generator must not emit.
fn (mut g AsmGen) gen_num(node &ast.Node) {
	mut lit := node
	ty := lit.ty
	if ty == unsafe { nil } {
		g.errors << 'a literal reached code generation with no type'
		g.line('  mov $0, %rax')
		return
	}
	if ty.kind == .basic {
		if ty.basic == .float_ {
			g.line('  mov $${f32_bits(f32(node.fval))}, %rax')
			g.line('  movq %rax, %xmm0')
			return
		}
		if ty.basic == .double_ {
			g.line('  mov $${f64_bits(node.fval)}, %rax')
			g.line('  movq %rax, %xmm0')
			return
		}
		if ty.basic == .ldouble_ {
			// An 80-bit value is ten bytes and the instruction wants it in memory, so
			// it is written into the red zone below %rsp and loaded from there.
			bytes := f80_bytes(lit.fval)
			mut lo := u64(0)
			for i in 0 .. 8 {
				lo |= u64(bytes[i]) << (8 * i)
			}
			mut hi := u64(0)
			for i in 8 .. 10 {
				hi |= u64(bytes[i]) << (8 * (i - 8))
			}
			g.line('  mov $${lo}, %rax')
			g.line('  mov %rax, -16(%rsp)')
			g.line('  mov $${hi}, %rax')
			g.line('  mov %rax, -8(%rsp)')
			g.line('  fldt -16(%rsp)')
			return
		}
	}
	g.line('  mov $${node.num}, %rax')
}

// f80_bytes is the 80-bit extended encoding of a double, little-endian.
//
// The extended format has a 15-bit exponent biased by 16383 and an *explicit*
// integer bit, which a double's eight bytes do not have, so the conversion is
// arithmetic rather than a copy. This matters because the target's `long double`
// is measured at 8 bytes while x86's 80-bit format is what `fldt` loads, so the
// two only agree above 2^63.
fn f80_bytes(d f64) []u8 {
	bits := u64(d)
	mut sign := u64(0)
	if d < 0 {
		sign = 1
	}
	exp := (bits >> 52) & 0x7ff
	mut frac := bits & 0xfffffffffffff
	mut mant := u64(0)
	mut biased := u64(0)
	if exp == 0 {
		if frac == 0 {
			// Zero: the mantissa and the exponent are already right.
		} else {
			// A subnormal double has no normal extended form. It is shifted left
			// until its leading bit emerges and the exponent records how far it moved.
			mut e := 0
			for frac & 0x0010000000000000 == 0 {
				frac <<= 1
				e++
			}
			mant = frac
			biased = u64(16383 - 1022 - e)
		}
	} else if exp == 0x7ff {
		// An infinity or a NaN, both of which have the maximum exponent.
		mant = 0x8000000000000000 | (frac << 11)
		biased = 0x7fff
	} else {
		mant = 0x8000000000000000 | (frac << 11)
		biased = exp - 1023 + 16383
	}
	mut out := []u8{len: 10, init: 0}
	for i in 0 .. 8 {
		out[i] = u8(mant >> (8 * i))
	}
	for i in 0 .. 2 {
		out[8 + i] = u8((biased << 1 | sign) >> (8 * i))
	}
	return out
}

// gen_neg negates the accumulator.
//
// A float is negated by flipping its sign bit, which is cheaper than a subtract
// and correct for every value, including the ones a subtract treats specially.
fn (mut g AsmGen) gen_neg(ty &ast.Type) {
	if ty != unsafe { nil } && ty.kind == .basic {
		if ty.basic == .float_ {
			g.line('  mov $1, %rax')
			g.line('  shl $31, %rax')
			g.line('  movq %rax, %xmm1')
			g.line('  xorps %xmm1, %xmm0')
			return
		}
		if ty.basic == .double_ {
			g.line('  mov $1, %rax')
			g.line('  shl $63, %rax')
			g.line('  movq %rax, %xmm1')
			g.line('  xorpd %xmm1, %xmm0')
			return
		}
		if ty.basic == .ldouble_ {
			g.line('  fchs')
			return
		}
	}
	g.line('  neg %rax')
}

// gen_bitfield_extract narrows a loaded bitfield to its own width.
//
// The load brought in the whole storage unit, so the field has to be shifted up to
// the top of the register and brought back down — the only way to sign- or
// zero-extend it in one pair of shifts.
fn (mut g AsmGen) gen_bitfield_extract(node &ast.Node) {
	m := node.member or { return }
	if !m.is_bitfield {
		return
	}
	g.line('  shl $${64 - m.bit_width - m.bit_offset}, %rax')
	if m.ty.is_unsigned {
		g.line('  shr $${64 - m.bit_width}, %rax')
	} else {
		g.line('  sar $${64 - m.bit_width}, %rax')
	}
}

// gen_assign stores the right operand through the left one's address.
//
// The address is evaluated first and pushed, so the operands are evaluated in the
// order C requires and a target with a side effect is evaluated once.
fn (mut g AsmGen) gen_assign(node &ast.Node) {
	g.gen_addr(node.lhs)
	g.push()
	g.gen_expr(node.rhs)

	if m := bitfield_of(node.lhs) {
		g.gen_assign_bitfield(node, m)
		return
	}
	g.store(node.ty)
}

// bitfield_of returns the member of a node that is a bitfield assignment's target.
fn bitfield_of(lhs &ast.Node) ?ast.Member {
	if lhs.kind != .member {
		return none
	}
	m := lhs.member or { return none }
	if !m.is_bitfield {
		return none
	}
	return m
}

// gen_assign_bitfield merges a value into a bitfield's storage unit.
//
// The neighbouring fields have to survive, so the unit is read, the new value is
// masked into its own bits, and the two are combined. The value of the assignment
// is the value stored rather than the unit, so that is kept in %r8 across the merge.
fn (mut g AsmGen) gen_assign_bitfield(node &ast.Node, m ast.Member) {
	g.line('  mov %rax, %r8')
	mask := (i64(1) << m.bit_width) - 1
	// `%r10` for the value being merged, not `%rdi`: `%rdi` is non-volatile on this
	// target, and this runs in the middle of an arbitrary expression, so the value
	// the caller's own caller relied on would be gone. `%rcx` is unavailable too —
	// `store` below pops the destination address into it — and `%r8`, `%r9`, `%r11`
	// and `%rax` are each already holding something here.
	g.line('  mov %rax, %r10')
	// The mask is staged through a register rather than used as an immediate, because
	// `and` only accepts a sign-extended 32-bit one and this is a 64-bit value: for a
	// 40-bit field it is `1099511627775`, and `and $1099511627775, %rdi` is rejected by
	// GNU as with `operand type mismatch for 'and'`. `mov` does take the full width —
	// that is what `movabs` is — so the value is loaded and then the `and` is between
	// registers.
	g.line('  mov $${mask}, %r11')
	g.line('  and %r11, %r10')
	g.line('  shl $${m.bit_offset}, %r10')

	// The address is on the stack, under the new value.
	g.line('  mov (%rsp), %rax')
	g.load(m.ty)

	keep := ~(mask << m.bit_offset)
	g.line('  mov $${keep}, %r9')
	g.line('  and %r9, %rax')
	g.line('  or %r10, %rax')
	g.store(node.ty)
	g.line('  mov %r8, %rax')
}

// gen_funcall emits a call and marshals its arguments.
//
// The callee's address goes through %r10 rather than being called directly,
// because %r10 is not an argument register and so survives loading the arguments
// into theirs.
fn (mut g AsmGen) gen_funcall(node &ast.Node) {
		// The VLA allocator is not a function, so it is emitted here rather than called.
		if node.lhs.kind == .var_ref && node.lhs.var.name == 'alloca' {
			g.gen_expr(node.args[0])
			g.line('  mov %rax, %r11')
			g.builtin_alloca()
			return
		}

	_, classes := g.classify_args(node)
	stack_args := g.push_args(node, classes)
	g.gen_expr(node.lhs)

	mut gp := 0
	mut fp := 0

	if node.ret_buffer != unsafe { nil } && node.ty.size > 16 {
		g.pop(arg_regs[gp])
		gp++
	}

	for i, arg in node.args {
		c := classes[i]
		ty := arg.ty
		if ty.kind == .struct_ || ty.kind == .union_ {
			if ty.size > 16 || c.by_stack {
				continue
			}
			if c.fp1 {
				g.popf(fp)
				fp++
			} else {
				g.pop(arg_regs[gp])
				gp++
			}
			if ty.size > 8 {
				if c.fp2 {
					g.popf(fp)
					fp++
				} else {
					g.pop(arg_regs[gp])
					gp++
				}
			}
			continue
		}
		if ty.kind == .basic && ty.basic == .ldouble_ {
			// The address `push_args_pass` pushed is loaded like any other pointer-sized
			// argument, which is what it now is.
			if !c.by_stack && gp < gp_max {
				g.pop(arg_regs[gp])
				gp++
			}
			continue
		}
		if ty.kind == .basic && (ty.basic == .float_ || ty.basic == .double_) {
			is_variadic := node.func_ty != unsafe { nil } && node.func_ty.is_variadic
			if !c.by_stack && fp < fp_max {
				g.popf(fp)
			}
			// [MS x64 3.2] A variadic callee walks only the integer register copies, so
			// the value is also written into the general register that this argument's
			// position selects.
			//
			// The register is `arg_regs[gp]`, the *position among all the arguments*, and
			// not `arg_regs[fp]`, the position among the floating-point ones. Measured:
			// for `printf("a=%g b=%s c=%d", 3.5, "hi", 7)` gcc leaves the format string in
			// `%rcx`, 3.5 in `%xmm0` *and* `%rdx`, `"hi"` in `%r8` and 7 in `%r9`.
			//
			// Indexing by `fp` put the mirror in `%rcx` and overwrote the format string,
			// so the call died with an access violation and printed nothing at all — while
			// every unit test stayed green, because nothing they generated ever reached
			// the C library.
			//
			// `movq`, not `movsd`: moving between an XMM and a general register with an
			// SSE mnemonic is not an instruction, and the assembler says
			// `operand type mismatch for movsd` rather than anything about the ABI.
			// A `float` is mirrored whole; the callee reads only its low 32 bits.
			//
			// `gp < gp_max` also covers the case where the argument went on the stack:
			// on a variadic call every argument advances `gp`, the integer ones in
			// `classify_args` and the floating-point ones just above, so `gp` can never
			// fall back below `gp_max` once it has passed it. An argument with no
			// general register left has no mirror to write, which is the same fact.
			if is_variadic && gp < gp_max {
				g.line('  movq %xmm${fp}, ${arg_regs_mirror[gp]}')
				gp++
			}
			fp++
		} else if !c.by_stack && gp < gp_max {
			g.pop(arg_regs[gp])
			gp++
		}
	}

	g.line('  mov %rax, %r10')
	// [MS x64 2.2.5] The callee's home area is the last thing reserved, immediately
	// before the `call`, because the argument values are still on the stack waiting to be
	// popped into their registers and reserving below them would move `%rsp` out from
	// under the `pop`s. gcc takes the same 32 bytes out of the prologue once instead;
	// taking them out per call site costs one instruction and keeps the depth accounting
	// local to the call.
	//
	// There is deliberately no `%al` here. The vector-register count is a psABI
	// requirement for the callee's register save area and has no meaning in the Microsoft
	// ABI, which has no such save area.
	g.line('  sub $${shadow_space}, %rsp')
	g.line('  call *%r10')
	// The by-reference spill is released here too. It is not part of `stack_args` — those
	// are the arguments the *callee* pops — so without this the frame would grow by 16
	// bytes at every call passing a `long double`, and the function would end with a
	// depth it could never account for.
	mut spill := 0
	for i, arg in node.args {
		if arg.ty.kind == .basic && arg.ty.basic == .ldouble_ && !classes[i].by_stack {
			spill += 2
		}
	}
	g.line('  add $${shadow_space + (stack_args + spill) * 8}, %rsp')
	g.depth -= stack_args + spill

	// A narrow return type leaves the upper bits of %rax undefined and the next
	// operation would read them, so they are cleared here rather than at every use.
	ty := node.ty
	if ty != unsafe { nil } && ty.kind == .basic {
		if ty.basic == .bool_ {
			g.line('  movzx %al, %eax')
			return
		}
		if ty.basic == .char_ {
			if ty.is_unsigned {
				g.line('  movzbl %al, %eax')
			} else {
				g.line('  movsbl %al, %eax')
			}
			return
		}
		if ty.basic == .short_ {
			if ty.is_unsigned {
				g.line('  movzwl %ax, %eax')
			} else {
				g.line('  movswl %ax, %eax')
			}
			return
		}
	}

	// A small aggregate comes back in registers, and its address is what the
	// expression's value is.
	if node.ret_buffer != unsafe { nil } && node.ty.size <= 16 {
		g.copy_ret_buffer(node.ret_buffer)
		g.line('  lea ${node.ret_buffer.offset}(%rbp), %rax')
	}
}

// gen_binary emits an operator, which is the rest of the expression grammar.
//
// Floating and integer arithmetic are separate because they use different
// registers and different compare instructions, and the *unsigned* integer
// compares are separate again because the condition codes differ.
fn (mut g AsmGen) gen_binary(node &ast.Node) {
	lhs := node.lhs
	if lhs == unsafe { nil } || lhs.ty == unsafe { nil } {
		g.errors << 'operator with no left operand at line ${node.tok.line.disp_line}'
		return
	}
	lt := lhs.ty

	if lt.kind == .basic && (lt.basic == .float_ || lt.basic == .double_) {
		g.gen_float_binary(node, lt)
		return
	}
	if lt.kind == .basic && lt.basic == .ldouble_ {
		g.gen_f80_binary(node)
		return
	}

	g.gen_expr(node.rhs)
	g.push()
	g.gen_expr(node.lhs)
	// The right operand is popped into a *volatile* register. `%rdi` is not one on
	// this target: Windows x64 keeps RBX, RBP, RDI, RSI and R12-R15 across a call,
	// where Linux keeps only RBX, RBP and R12-R15. Popping into `%rdi` therefore
	// destroys a value the *callee* had been promised it could rely on, and the
	// symptom is not in the function that did it — a comparator built this way
	// returns a correct comparison and then takes libc's `qsort` down with it,
	// because `qsort` was holding one of those registers across the call. Every
	// unit test stayed green, because none of them called a function that depends
	// on the register surviving.
	//
	// `%rcx` is already in `asm_scratch` below as one of this generator's
	// caller-saved scratch registers, so it is the same class of choice. Using it
	// here also removes the `mov %rdi, %rcx` that the shifts needed to reach `%cl`.
	g.pop('%rcx')

	// A pointer or an eight-byte value needs the wide registers. The test is the
	// width rather than the type being `long`, because a `long` is four bytes on
	// this target — one of the three places the measured ABI differs from chibicc's.
	wide := lt.size == 8 || lt.base != unsafe { nil }
	ax := if wide { '%rax' } else { '%eax' }
	di := if wide { '%rcx' } else { '%ecx' }
	dx := if wide { '%rdx' } else { '%edx' }

	match node.kind {
		.add {
			g.line('  add ${di}, ${ax}')
		}
		.sub {
			g.line('  sub ${di}, ${ax}')
		}
		.mul {
			g.line('  imul ${di}, ${ax}')
		}
		.div, .mod {
			if node.ty.is_unsigned {
				// `div` reads the high half of the dividend as part of the number, so
				// it has to be zero first or it divides by the wrong value.
				g.line('  mov $0, ${dx}')
				g.line('  div ${di}')
			} else {
				// `cqo` sign-extends into %rdx:%rax and `cdq` is its 32-bit form.
				// Using the wrong one is the classic sign-extension defect.
				if lt.size == 8 {
					g.line('  cqo')
				} else {
					g.line('  cdq')
				}
				g.line('  idiv ${di}')
			}
			// A division leaves the remainder in %rdx and the quotient in %rax.
			if node.kind == .mod {
				g.line('  mov %rdx, %rax')
			}
		}
		.bit_and {
			g.line('  and ${di}, ${ax}')
		}
		.bit_or {
			g.line('  or ${di}, ${ax}')
		}
		.bit_xor {
			g.line('  xor ${di}, ${ax}')
		}
		.eq, .ne, .lt, .le {
			g.line('  cmp ${di}, ${ax}')
			match node.kind {
				.eq { g.line('  sete %al') }
				.ne { g.line('  setne %al') }
				.lt {
					// An unsigned compare is `setb` and a signed one `setl`. They are
					// different instructions, not a flag.
					if lt.is_unsigned {
						g.line('  setb %al')
					} else {
						g.line('  setl %al')
					}
				}
				else {
					if lt.is_unsigned {
						g.line('  setbe %al')
					} else {
						g.line('  setle %al')
					}
				}
			}
			g.line('  movzb %al, %rax')
		}
		.shl {
			// The operand is already in `%rcx`, so the count is in `%cl` with no move.
			g.line('  shl %cl, ${ax}')
		}
		.shr {
			if lt.is_unsigned {
				g.line('  shr %cl, ${ax}')
			} else {
				g.line('  sar %cl, ${ax}')
			}
		}
		else {
			g.errors << 'operator at line ${node.tok.line.disp_line} is not a binary operator this generator emits'
		}
	}
}

fn (mut g AsmGen) gen_float_binary(node &ast.Node, lt &ast.Type) {
	sfx := if lt.basic == .float_ { 'ss' } else { 'sd' }
	g.gen_expr(node.rhs)
	g.pushf()
	g.gen_expr(node.lhs)
	g.popf(1)

	match node.kind {
		.add { g.line('  add${sfx} %xmm1, %xmm0') }
		.sub { g.line('  sub${sfx} %xmm1, %xmm0') }
		.mul { g.line('  mul${sfx} %xmm1, %xmm0') }
		.div { g.line('  div${sfx} %xmm1, %xmm0') }
		.eq, .ne, .lt, .le {
			// `ucomiss` sets the unordered flags as well, so an equality has to clear
			// the parity flag: a NaN compares unequal to itself, and a plain `sete`
			// would say it is equal.
			g.line('  ucomi${sfx} %xmm0, %xmm1')
			match node.kind {
				.eq {
					g.line('  sete %al')
					g.line('  setnp %dl')
					g.line('  and %dl, %al')
				}
				.ne {
					g.line('  setne %al')
					g.line('  setp %dl')
					g.line('  or %dl, %al')
				}
				.lt { g.line('  seta %al') }
				else { g.line('  setae %al') }
			}
			g.line('  and $1, %al')
			g.line('  movzb %al, %rax')
		}
		else {
			g.errors << 'operator at line ${node.tok.line.disp_line} is not a floating operator this generator emits'
		}
	}
}

fn (mut g AsmGen) gen_f80_binary(node &ast.Node) {
	g.gen_expr(node.lhs)
	g.gen_expr(node.rhs)
	match node.kind {
		.add { g.line('  faddp') }
		.sub { g.line('  fsubrp') }
		.mul { g.line('  fmulp') }
		.div { g.line('  fdivrp') }
		.eq, .ne, .lt, .le {
			g.line('  fcomip')
			g.line('  fstp %st(0)')
			match node.kind {
				.eq { g.line('  sete %al') }
				.ne { g.line('  setne %al') }
				.lt { g.line('  seta %al') }
				else { g.line('  setae %al') }
			}
			g.line('  movzb %al, %rax')
		}
		else {
			g.errors << 'operator at line ${node.tok.line.disp_line} is not an extended-precision operator this generator emits'
		}
	}
}

// gen_stmt emits a statement.
//
// Every control-flow form is the same shape: evaluate, compare against zero, and
// jump to a label the generator invented and therefore knows is unique.
fn (mut g AsmGen) gen_stmt(node &ast.Node) {
	if node == unsafe { nil } {
		return
	}
	match node.kind {
		.if_ {
			c := g.next_label()
			g.gen_expr(node.cond)
			g.cmp_zero(node.cond.ty)
			g.line('  je .L.else.${c}')
			g.gen_stmt(node.then)
			g.line('  jmp .L.end.${c}')
			g.line('.L.else.${c}:')
			if node.els != unsafe { nil } {
				g.gen_stmt(node.els)
			}
			g.line('.L.end.${c}:')
			return
		}
		.for_ {
			c := g.next_label()
			if node.init != unsafe { nil } {
				g.gen_stmt(node.init)
			}
			g.line('.L.begin.${c}:')
			if node.cond != unsafe { nil } {
				g.gen_expr(node.cond)
				g.cmp_zero(node.cond.ty)
				// The condition's failure jumps to the loop's own break label rather
				// than a generated one, because a `break` has to land in the same place.
				g.line('  je ${node.brk_label}')
			}
			g.gen_stmt(node.then)
			g.line('${node.cont_label}:')
			if node.inc != unsafe { nil } {
				g.gen_expr(node.inc)
			}
			g.line('  jmp .L.begin.${c}')
			g.line('${node.brk_label}:')
			return
		}
		.do_ {
			c := g.next_label()
			g.line('.L.begin.${c}:')
			g.gen_stmt(node.then)
			g.line('${node.cont_label}:')
			g.gen_expr(node.cond)
			g.cmp_zero(node.cond.ty)
			g.line('  jne .L.begin.${c}')
			g.line('${node.brk_label}:')
			return
		}
		.switch_ {
			g.gen_expr(node.cond)
			// The value is compared once per case, and a range is a subtract and a
			// compare, because a chain of equality tests would not cover one.
			w := node.cond.ty.size == 8
			ax := if w { '%rax' } else { '%eax' }
			// `%rcx`, not `%rdi` — RDI is non-volatile on this target, and a range
			// comparison is arithmetic a caller may have depending registers round.
			di := if w { '%rcx' } else { '%ecx' }
			for c in node.cases {
				if c.begin == c.end {
					g.line('  cmp $${c.begin}, ${ax}')
					g.line('  je ${c.unique_label}')
					continue
				}
				g.line('  mov ${ax}, ${di}')
				g.line('  sub $${c.begin}, ${di}')
				g.line('  cmp $${c.end - c.begin}, ${di}')
				g.line('  jbe ${c.unique_label}')
			}
			if node.default_case != unsafe { nil } {
				g.line('  jmp ${node.default_case.unique_label}')
			}
			g.line('  jmp ${node.brk_label}')
			g.gen_stmt(node.then)
			g.line('${node.brk_label}:')
			return
		}
		.case_ {
			g.line('${node.unique_label}:')
			g.gen_stmt(node.lhs)
			return
		}
		.block_ {
			for s in node.body {
				g.gen_stmt(s)
			}
			return
		}
		.goto_ {
			g.line('  jmp ${node.unique_label}')
			return
		}
		.goto_expr {
			g.gen_expr(node.lhs)
			g.line('  jmp *%rax')
			return
		}
		.label {
			g.line('${node.unique_label}:')
			g.gen_stmt(node.lhs)
			return
		}
		.return_ {
			g.gen_return(node)
			return
		}
		.asm {
			g.gen_asm(node)
			return
		}
		.expr_stmt {
			// `va_start(ap, last);` and `va_end(ap);` are the statements the parser
			// produces for the two variadic builtins that have no value. They are
			// handled here rather than in `gen_expr` because an expression's contract is
			// that it leaves one value on the stack, and these leave none: emitting them
			// as expressions made `depth` grow by one per call and the function failed its
			// own end-of-body check with `left 1 values on the stack`.
			if node.lhs.kind == .va_start_ {
				g.gen_va_start(node.lhs)
				return
			}
			if node.lhs.kind == .null_stmt {
				return
			}
			g.gen_expr(node.lhs)
			return
		}
		else {}
	}
	g.errors << 'statement at line ${node.tok.line.disp_line} is not a statement this generator emits'
}

// gen_asm emits a GNU `__asm__` statement.
//
// Each operand's address is materialised into its own scratch register, and `%N` is
// replaced by that register as a memory operand. A register rather than a stack slot,
// because the template spells `%N` where a *memory reference* belongs: `fldl %1` has to
// load x's value, so `%1` must become `(%rcx)` holding x's address — not a slot holding
// that address, which would load the address itself as a double. That is what the first
// attempt did, and it made `lrint(2.7)` return 247 instead of 3.
//
// The scratch registers are all caller-saved on this target, which is the only reason
// using them is safe: nothing in this generator's contract holds a live value in one
// across a statement, the value stack being in memory. An asm template that clobbers
// them is therefore clobbering something nothing was relying on. The count is capped so
// that running out is a report rather than a silently dropped operand.
const asm_scratch = ['%rcx', '%rdx', '%r8', '%r9', '%r10', '%r11']

fn (mut g AsmGen) gen_asm(node &ast.Node) {
	if node.asm_ops.len > asm_scratch.len {
		g.errors << 'asm at line ${node.tok.line.disp_line} has ${node.asm_ops.len} operands; this generator stages at most ${asm_scratch.len}'
		return
	}
	for i in 0 .. node.asm_ops.len {
		g.gen_addr(node.asm_ops[i])
		g.line('  mov %rax, ${asm_scratch[i]}')
	}

	// Substitute from the highest operand number down, so an earlier substitution's text
	// can never be read as part of a later one: `%10` contains `%1` and would otherwise
	// become `(%rcx)0`.
	mut out := node.asm_template
	for i := node.asm_ops.len - 1; i >= 0; i-- {
		out = out.replace('%${i}', '(${asm_scratch[i]})')
	}
	for line in out.split_into_lines() {
		t := line.trim_space()
		if t != '' {
			g.line('  ${t}')
		}
	}
}

// gen_return emits a `return`, which is a jump to the one epilogue.
//
// Every exit goes through the epilogue rather than carrying its own sequence,
// because the epilogue is what restores the stack pointer — and a function
// containing a VLA has stack to give back.
fn (mut g AsmGen) gen_return(node &ast.Node) {
	if node.lhs != unsafe { nil } {
		g.gen_expr(node.lhs)
		ty := node.lhs.ty
		if ty != unsafe { nil } && (ty.kind == .struct_ || ty.kind == .union_) {
			if ty.size <= 16 {
				g.copy_struct_reg()
			} else {
				g.copy_struct_mem()
			}
		}
	}
	g.line('  jmp .L.return.${g.current_fn.name}')
}

// emit_text writes every function definition.
//
// The prologue reserves the frame and spills the parameters that arrived in
// registers into it, because the body addresses them all as locals. The epilogue
// is the single point every `return` jumps to.
fn (mut g AsmGen) emit_text(globals []&ast.Obj) {
	for fun in globals {
		if !fun.is_function || !fun.is_definition {
			continue
		}
		if !fun.is_static {
			g.line('  .globl ${fun.name}')
		}
		g.line('  .text')
		g.line('${fun.name}:')
		g.current_fn = fun
		g.depth = 0

		g.line('  push %rbp')
		g.line('  mov %rsp, %rbp')
		// A frame larger than a page has to be reached one page at a time. `sub $N,
		// %rsp` on its own moves the stack pointer past the guard page, and the
		// first store into the frame lands on a page the system has never
		// committed — an access violation, not a slow path. Windows x64 names the
		// probe as a requirement rather than an optimisation, and the reference
		// reaches for `___chkstk_ms` exactly here.
		//
		// It is done inline instead of by calling out, because that symbol is in
		// libgcc and this generator cannot assume it was linked. The cost is the
		// same instruction per page, and the frames it applies to are the ones
		// where a store into the frame is going to be a `rep stosb` over kilobytes
		// anyway.
		//
		// The descent is by whole pages and the remainder afterwards, so the final
		// %rsp is the same as `sub $N` would leave for any N — including one that
		// is not a multiple of 16, where the remainder is what keeps it aligned.
		if fun.stack_size > 4096 {
			pid := g.next_label()
			g.line('  mov $${fun.stack_size}, %rax')
			g.line('.L.probe.${pid}:')
			g.line('  cmp $4096, %rax')
			g.line('  jbe .L.probe.last.${pid}')
			g.line('  sub $4096, %rsp')
			g.line('  movq $0, (%rsp)')
			g.line('  sub $4096, %rax')
			g.line('  jmp .L.probe.${pid}')
			g.line('.L.probe.last.${pid}:')
			g.line('  sub %rax, %rsp')
			g.line('  movq $0, (%rsp)')
		} else if fun.stack_size > 0 {
			g.line('  sub $${fun.stack_size}, %rsp')
		}
		if fun.alloca_bottom != unsafe { nil } {
			g.line('  mov %rsp, ${fun.alloca_bottom.offset}(%rbp)')
		}

		// The variadic spill comes first because it writes the *home* slots, which is
		// where `spill_params` puts a named register parameter too. The two write the
		// same bytes with the same values — the argument registers hold the named
		// parameters as well as the variadic ones — so the order between them does not
		// change the result, and `spill_params` alone would leave the registers past the
		// last named parameter unwritten.
		if fun.ty.is_variadic {
			g.spill_va_regs()
		}
		g.spill_params(fun)

		for s in fun.body {
			g.gen_stmt(s)
		}
		if g.depth != 0 {
			g.errors << 'function "${fun.name}" left ${g.depth} values on the stack'
		}

		// [C11 5.1.2.2.3] Reaching the end of main returns 0. It is undefined for
		// every other function, and a trap there would be unhelpful.
		if fun.name == 'main' {
			g.line('  mov $0, %rax')
		}

		g.line('.L.return.${fun.name}:')
		g.line('  mov %rbp, %rsp')
		g.line('  pop %rbp')
		g.line('  ret')
		g.current_fn = unsafe { nil }
	}
}

// gen_va_start emits `__builtin_va_start(ap, last)`.
//
// It is one store of a frame-relative constant: the `va_list` is a pointer and the
// first variadic argument's address is decided by `assign_lvar_offsets`, which counts
// the slots the named parameters occupy. Measured against gcc, which for
// `int vsum(int n, ...)` emits `leaq 24(%rbp), %rax` — the same value, since `n` is
// the only named parameter and takes one slot.
//
// The frame offset rather than the offset of the last named parameter matters. The
// two agree whenever `last` arrived in a register, and disagree whenever it did not:
// for `void f(int n, struct Big b, ...)` the by-address struct `b` lives above
// `incoming_base`, so `&b + 8` is past the end of the arguments, while the home area
// says slot two. gcc agrees with the second, measured as `ap - &a == 16`.
fn (mut g AsmGen) gen_va_start(node &ast.Node) {
	g.gen_addr(node.lhs) // %rax = &ap
	g.line('  lea ${g.current_fn.va_start_offset}(%rbp), %r10')
	g.line('  mov %r10, (%rax)')
}

// gen_va_arg emits `__builtin_va_arg(ap, T)`.
//
// On this target the whole of it is "read the value at `*ap`, then advance `ap`",
// and the stride is fixed by the type at compile time:
//
//	size <= 8   the value is in the slot             stride 8
//	size <= 16  the value is in the slot             stride 16
//	size > 16   the slot holds the object's address  stride 8
//
// All three measured, against gcc and tcc, which agree on every shape: a
// 16-byte struct occupies two slots and both halves read back; a 32-byte struct's
// slot holds an address and reading it yields `movq (%rax), %rax` twice; six ints
// come out as 1..6 with a stride of eight each.
//
// A `long double` takes the third path even though it is eight bytes here, because
// `classify_args` passes it by reference — [MS x64 2.2.5] passes anything wider
// than one eightbyte that is not a two-eightbyte aggregate by reference — so its
// slot holds an address too.
//
// The read has to come before the advance, and the value has to survive it, so the
// address of the `va_list` object is held aside for the whole sequence.
//
// It pushes nothing, which is the whole of what the `depth` accounting is about. An
// expression in this generator leaves its value in `%rax` or `%xmm0` and does *not*
// push; `depth` counts only the explicit `push()` calls that spill an intermediate. An
// earlier version of this function pushed its result, and every variadic function
// failed its end-of-body check with `left N values on the stack` — one per `va_arg`,
// so `mixed` reported three. The count was right and the code was wrong.
fn (mut g AsmGen) gen_va_arg(node &ast.Node) {
	ty := node.ty
	sz := ty.size
	is_ldouble := ty.kind == .basic && ty.basic == .ldouble_
	by_ref := sz > 16 || is_ldouble

	// `%r11` holds the address of the `va_list` object and `%rax` walks the slots.
	// They have to be kept apart: the advance writes *through the object's address*
	// while the read dereferences the pointer the object holds, and using one register
	// for both overwrites an argument slot instead of the pointer. With one register,
	// `addq $8, (%r10)` wrote to the slot `ap` addresses — the register save area — so
	// each read saw the previous advance as its own value: a probe asking for six
	// integers got `11 19 27 35 43 51`, eight bytes of drift per step.
	//
	// `%r11` is chosen because nothing else in this generator names it: `%rax` and
	// `%rdx` carry operands, `%rdi` the argument-setup address, and `%r8`/`%r10` the
	// two scratch registers used elsewhere.
	g.gen_addr(node.lhs) // %rax = &ap
	g.line('  mov %rax, %r11') // %r11 = &ap, kept across the load
	g.line('  mov (%r11), %rax') // %rax = ap

	if by_ref {
		g.line('  mov (%rax), %rax') // the slot holds the address of the object
		if is_ldouble {
			g.line('  fldt (%rax)')
		}
		g.line('  addq $8, (%r11)')
		return
	}

	if sz > 8 {
		// Two eightbytes passed by value in a pair of registers, so two consecutive
		// slots and a stride of sixteen. The result is the address of the pair, which
		// is what an aggregate's value is here, so `%rax` already holds it.
		g.line('  addq $16, (%r11)')
		return
	}

	// The ordinary case: a scalar, or a one-slot aggregate, in one slot.
	g.load(ty)
	g.line('  addq $8, (%r11)')
}

// spill_va_regs writes the four argument registers into the home slots a variadic
// callee's `va_list` walks.
//
// These four stores are the whole of the variadic callee on this target. There is
// no register save area and no `gp_offset`/`fp_offset` pair: the home slots at
// 16/24/32/40(`%rbp`) already are the caller's shadow area, so writing the
// registers there makes them contiguous with the stack arguments that follow at
// `incoming_base`, and a `va_list` is a plain pointer into that run.
//
// Measured from `gcc -S` for `int vsum(int n, ...)`:
//
//	movq	%rcx, 16(%rbp)
//	movq	%rdx, 24(%rbp)
//	movq	%r8, 32(%rbp)
//	movq	%r9, 40(%rbp)
//	leaq	24(%rbp), %rax        # what va_start puts in ap
//
// All four are written unconditionally, including registers no named parameter
// reached: that is the difference between a variadic prologue and an ordinary
// parameter spill, and it is why `spill_params` cannot be reused for it — that one
// walks `fun.params` and stops at the last one.
fn (mut g AsmGen) spill_va_regs() {
	for i in 0 .. gp_max {
		g.line('  movq ${arg_regs[i]}, ${va_start_offset + i * 8}(%rbp)')
	}
}

// spill_params moves the parameters that arrived in registers into their frame
// slots, so the body can address every parameter the same way.
fn (mut g AsmGen) spill_params(fun &ast.Obj) {
	mut gp := 0
	mut fp := 0
	for param in fun.params {
		// A positive offset means the caller put it on the stack, where it already is.
		if param.offset > 0 {
			continue
		}
		ty := param.ty
		if ty.kind == .struct_ || ty.kind == .union_ {
			if has_flonum(ty, 0, 8, 0) {
				g.store_fp(fp, param.offset, imin(8, ty.size))
			} else {
				g.store_gp(gp, param.offset, imin(8, ty.size))
			}
			gp++
			if ty.size > 8 {
				if has_flonum(ty, 8, 16, 0) {
					g.store_fp(fp, param.offset + 8, ty.size - 8)
				} else {
					g.store_gp(gp, param.offset + 8, ty.size - 8)
				}
				fp++
			}
			continue
		}
		if ty.kind == .basic && (ty.basic == .float_ || ty.basic == .double_) {
			g.store_fp(fp, param.offset, ty.size)
			fp++
			continue
		}
		if ty.kind == .basic && ty.basic == .ldouble_ {
			// The register holds the *address* of the caller's 16 bytes, not the value,
			// so the value is loaded through it and then written to the frame slot. This
			// is the same two instructions the psABI needed in the other direction, which
			// is how the mistake is easy to make: `fldt` from the register, `fstpt` to
			// the slot, and the general-register spill is not used at all.
			reg := arg_regs[gp]
			g.line('  fldt (${reg})')
			g.line('  fstpt ${param.offset}(%rbp)')
			gp++
			continue
		}
		g.store_gp(gp, param.offset, ty.size)
		gp++
	}
}
