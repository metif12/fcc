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
	by_stack bool
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
				if fp >= fp_max {
					c.by_stack = true
					stack++
				}
				fp++
			} else if ty.basic == .ldouble_ {
				// The 80-bit format has no register class, so it is always on the stack,
				// and it takes two slots.
				c.by_stack = true
				stack += 2
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
	for c in classes {
		if c.by_stack {
			total++
		}
	}
	// [psABI] The end of the argument area must be 16-byte aligned, so an odd number
	// of eight-byte slots gets a padding slot.
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
	// Right to left, so the first stack argument ends up lowest in the frame, which
	// is where the callee expects to find it.
	mut i := node.args.len - 1
	for i >= 0 {
		if classes[i].by_stack == first_pass {
			i--
			continue
		}
		arg := node.args[i]
		g.gen_expr(arg)
		ty := arg.ty
		if ty.kind == .struct_ || ty.kind == .union_ {
			g.push_struct(ty)
		} else if ty.kind == .basic
			&& (ty.basic == .float_ || ty.basic == .double_) {
			g.pushf()
		} else if ty.kind == .basic && ty.basic == .ldouble_ {
			g.line('  sub $16, %rsp')
			g.line('  fstpt (%rsp)')
			g.depth += 2
		} else {
			g.push()
		}
		i--
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
	g.line('  mov %rax, %rdi')

	if has_flonum(ty, 0, 8, 0) {
		if ty.size == 4 {
			g.line('  movss (%rdi), %xmm0')
		} else {
			g.line('  movsd (%rdi), %xmm0')
		}
		fp++
	} else {
		g.line('  mov $0, %rax')
		// Backwards, shifting left: the last byte has to end up highest.
		mut i := imin(8, ty.size) - 1
		for i >= 0 {
			g.line('  shl $8, %rax')
			g.line('  mov ${i}(%rdi), %al')
			i--
		}
		gp++
	}

	if ty.size > 8 {
		if has_flonum(ty, 8, 16, 0) {
			if ty.size == 4 {
				g.line('  movss 8(%rdi), %xmm${fp}')
			} else {
				g.line('  movsd 8(%rdi), %xmm${fp}')
			}
		} else {
			r1 := if gp == 0 { '%al' } else { '%dl' }
			r2 := if gp == 0 { '%rax' } else { '%rdx' }
			g.line('  mov $0, ${r2}')
			mut i := imin(16, ty.size) - 1
			for i >= 8 {
				g.line('  shl $8, ${r2}')
				g.line('  mov ${i}(%rdi), ${r1}')
				i--
			}
		}
	}
}

// copy_struct_mem copies a returned aggregate into the hidden buffer that arrived
// as the first argument.
fn (mut g AsmGen) copy_struct_mem() {
	ty := g.return_type()
	g.line('  mov ${g.current_fn.params[0].offset}(%rbp), %rdi')
	for i in 0 .. ty.size {
		g.line('  mov ${i}(%rax), %dl')
		g.line('  mov %dl, ${i}(%rdi)')
	}
}

// builtin_alloca carves space out of the stack for a variable-length array.
//
// A VLA's extent is not known until run time, so the allocation is a runtime
// operation: the temporary area already used above %rsp is shifted up by the
// requested size and the high-water mark moves with it, so that a `return` can
// give the space back.
fn (mut g AsmGen) builtin_alloca() {
	g.line('  add $15, %rdi')
	g.line('  and $0xfffffff0, %edi')

	bottom := g.current_fn.alloca_bottom.offset
	g.line('  mov ${bottom}(%rbp), %rcx')
	g.line('  sub %rsp, %rcx')
	g.line('  mov %rsp, %rax')
	g.line('  sub %rdi, %rsp')
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
	g.line('  sub %rdi, %rax')
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
			// `rep stosb` is memset(%rdi, %al, %rcx), and the object's size is known
			// here, so the whole clear is four instructions instead of one per element.
			g.line('  mov $${node.var.ty.size}, %rcx')
			g.line('  lea ${node.var.offset}(%rbp), %rdi')
			g.line('  mov $0, %al')
			g.line('  rep stosb')
			return
		}
		.cond_expr {
			c := g.next_label()
			g.gen_expr(node.cond)
			g.cmp_zero(node.cond.ty)
			g.line('  je .L.else.${c}')
			g.gen_expr(node.then)
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
	g.line('  mov %rax, %rdi')
	g.line('  and $${mask}, %rdi')
	g.line('  shl $${m.bit_offset}, %rdi')

	// The address is on the stack, under the new value.
	g.line('  mov (%rsp), %rax')
	g.load(m.ty)

	keep := ~(mask << m.bit_offset)
	g.line('  mov $${keep}, %r9')
	g.line('  and %r9, %rax')
	g.line('  or %rdi, %rax')
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
		g.line('  mov %rax, %rdi')
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
			continue
		}
		if ty.kind == .basic && (ty.basic == .float_ || ty.basic == .double_) {
			if !c.by_stack && fp < fp_max {
				g.popf(fp)
				fp++
			}
		} else if !c.by_stack && gp < gp_max {
			g.pop(arg_regs[gp])
			gp++
		}
	}

	g.line('  mov %rax, %r10')
	// [psABI] A variadic callee reads %rax for how many vector registers were used,
	// so it holds that count even when the callee is not variadic.
	g.line('  mov $${fp}, %rax')
	g.line('  call *%r10')
	if stack_args > 0 {
		g.line('  add $${stack_args * 8}, %rsp')
	}
	g.depth -= stack_args

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
	g.pop('%rdi')

	// A pointer or an eight-byte value needs the wide registers. The test is the
	// width rather than the type being `long`, because a `long` is four bytes on
	// this target — one of the three places the measured ABI differs from chibicc's.
	wide := lt.size == 8 || lt.base != unsafe { nil }
	ax := if wide { '%rax' } else { '%eax' }
	di := if wide { '%rdi' } else { '%edi' }
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
			g.line('  mov %rdi, %rcx')
			g.line('  shl %cl, ${ax}')
		}
		.shr {
			g.line('  mov %rdi, %rcx')
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
			di := if w { '%rdi' } else { '%edi' }
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
		.expr_stmt {
			g.gen_expr(node.lhs)
			return
		}
		else {}
	}
	g.errors << 'statement at line ${node.tok.line.disp_line} is not a statement this generator emits'
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
		if fun.stack_size > 0 {
			g.line('  sub $${fun.stack_size}, %rsp')
		}
		if fun.alloca_bottom != unsafe { nil } {
			g.line('  mov %rsp, ${fun.alloca_bottom.offset}(%rbp)')
		}

		g.emit_va_area(fun)
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

// emit_va_area writes the register save area a variadic function reads through
// `va_start`.
//
// The area is the six integer and eight SSE argument registers in a fixed order,
// because `va_arg` indexes it by position rather than by name.
fn (mut g AsmGen) emit_va_area(fun &ast.Obj) {
	if fun.va_area == unsafe { nil } {
		return
	}
	mut gp := 0
	mut fp := 0
	for param in fun.params {
		if param.ty.kind == .basic
			&& (param.ty.basic == .float_ || param.ty.basic == .double_) {
			fp++
		} else {
			gp++
		}
	}
	off := fun.va_area.offset

	g.line('  movl $${gp * 8}, ${off}(%rbp)')
	g.line('  movl $${fp * 8 + 48}, ${off + 4}(%rbp)')
	// The overflow area starts above the parameters the caller pushed, which is 16
	// bytes into this frame.
	g.line('  movq %rbp, ${off + 8}(%rbp)')
	g.line('  addq $16, ${off + 8}(%rbp)')
	g.line('  movq %rbp, ${off + 16}(%rbp)')
	g.line('  addq $${off + 24}, ${off + 16}(%rbp)')

	for i in 0 .. 6 {
		g.line('  movq ${arg_regs[i]}, ${off + 24 + i * 8}(%rbp)')
	}
	for i in 0 .. 8 {
		g.line('  movsd %xmm${i}, ${off + 72 + i * 8}(%rbp)')
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
		g.store_gp(gp, param.offset, ty.size)
		gp++
	}
}