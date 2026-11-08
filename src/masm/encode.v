module masm

// Operand model and x86-64 instruction encoder for the masm assembler.
//
// The size rule throughout: plain AT&T mnemonics (`mov`, `add`, ...) take
// their operand size from the widest register operand, exactly like GAS.
// A memory+immediate form needs an explicit suffix (`movq`), also like GAS.

pub enum OpKind {
	imm
	reg
	// ireg is an indirect register (`*%r10` in `call *%r10`).
	ireg
	mem
	rip
	sym
	numref
}

pub enum RegKind {
	r8
	r16
	r32
	r64
	xmm
}

pub struct Reg {
pub:
	kind RegKind
	idx  int
	// rex8 marks spl/bpl/sil/dil, which need a REX byte where ah-dh would not.
	rex8 bool
}

pub struct Operand {
pub:
	kind OpKind
	imm  i64
	reg  Reg
	base int
	disp int
	sym  string
	// numdir resolves `1b`/`2f`: -1 backward, +1 forward.
	numdir int
}

pub struct EncFixup {
pub:
	at          int
	label       string
	kind        RelocKind
	size        int
	addend      int
	numeric_dir int
}

pub fn parse_operand(s string) !Operand {
	t := s.trim_space()
	if t == '' {
		return error('empty operand')
	}
	if t.starts_with('*') {
		inner := parse_reg(t[1..].trim_space())!
		if inner.kind == .xmm {
			return error('bad indirect register "${t}"')
		}
		return Operand{
			kind: OpKind.ireg
			reg:  inner
		}
	}
	if t.starts_with('$') {
		return Operand{
			kind: OpKind.imm
			imm:  parse_number(t[1..])!
		}
	}
	if t.starts_with('%') {
		return Operand{
			kind: OpKind.reg
			reg:  parse_reg(t)!
		}
	}
	if t.contains('(') {
		open := t.index('(') or { return error('bad memory operand "${t}"') }
		if !t.ends_with(')') {
			return error('bad memory operand "${t}"')
		}
		head := t[..open].trim_space()
		inner := t[open + 1..t.len - 1].trim_space()
		if inner == '%rip' {
			return Operand{
				kind: OpKind.rip
				sym:  unquote_sym(head)
			}
		}
		base := parse_reg(inner)!
		if base.kind == .xmm {
			return error('bad memory base "${inner}"')
		}
		d := if head == '' { 0 } else { int(parse_number(head)!) }
		return Operand{
			kind: OpKind.mem
			base: base.idx
			disp: d
		}
	}
	if t.len >= 2 && (t[t.len - 1] == `b` || t[t.len - 1] == `f`) && is_numeric_label(t[..t.len - 1]) {
		dir := if t[t.len - 1] == `b` { -1 } else { 1 }
		return Operand{
			kind:   OpKind.numref
			sym:    t[..t.len - 1]
			numdir: dir
		}
	}
	return Operand{
		kind: OpKind.sym
		sym:  unquote_sym(t)
	}
}

fn parse_reg(s string) !Reg {
	t := s.trim_space()
	if t.starts_with('%xmm') {
		n := t[4..].int()
		if n < 0 || n > 15 || t[4..] != n.str() {
			return error('bad register "${s}"')
		}
		return Reg{ kind: .xmm, idx: n }
	}
	match t {
		'%rax' { return Reg{ kind: .r64, idx: 0 } }
		'%rcx' { return Reg{ kind: .r64, idx: 1 } }
		'%rdx' { return Reg{ kind: .r64, idx: 2 } }
		'%rbx' { return Reg{ kind: .r64, idx: 3 } }
		'%rsp' { return Reg{ kind: .r64, idx: 4 } }
		'%rbp' { return Reg{ kind: .r64, idx: 5 } }
		'%rsi' { return Reg{ kind: .r64, idx: 6 } }
		'%rdi' { return Reg{ kind: .r64, idx: 7 } }
		'%r8' { return Reg{ kind: .r64, idx: 8 } }
		'%r9' { return Reg{ kind: .r64, idx: 9 } }
		'%r10' { return Reg{ kind: .r64, idx: 10 } }
		'%r11' { return Reg{ kind: .r64, idx: 11 } }
		'%r12' { return Reg{ kind: .r64, idx: 12 } }
		'%r13' { return Reg{ kind: .r64, idx: 13 } }
		'%r14' { return Reg{ kind: .r64, idx: 14 } }
		'%r15' { return Reg{ kind: .r64, idx: 15 } }
		'%eax' { return Reg{ kind: .r32, idx: 0 } }
		'%ecx' { return Reg{ kind: .r32, idx: 1 } }
		'%edx' { return Reg{ kind: .r32, idx: 2 } }
		'%ebx' { return Reg{ kind: .r32, idx: 3 } }
		'%esp' { return Reg{ kind: .r32, idx: 4 } }
		'%ebp' { return Reg{ kind: .r32, idx: 5 } }
		'%esi' { return Reg{ kind: .r32, idx: 6 } }
		'%edi' { return Reg{ kind: .r32, idx: 7 } }
		'%r8d' { return Reg{ kind: .r32, idx: 8 } }
		'%r9d' { return Reg{ kind: .r32, idx: 9 } }
		'%r10d' { return Reg{ kind: .r32, idx: 10 } }
		'%r11d' { return Reg{ kind: .r32, idx: 11 } }
		'%r12d' { return Reg{ kind: .r32, idx: 12 } }
		'%r13d' { return Reg{ kind: .r32, idx: 13 } }
		'%r14d' { return Reg{ kind: .r32, idx: 14 } }
		'%r15d' { return Reg{ kind: .r32, idx: 15 } }
		'%ax' { return Reg{ kind: .r16, idx: 0 } }
		'%cx' { return Reg{ kind: .r16, idx: 1 } }
		'%dx' { return Reg{ kind: .r16, idx: 2 } }
		'%bx' { return Reg{ kind: .r16, idx: 3 } }
		'%sp' { return Reg{ kind: .r16, idx: 4 } }
		'%bp' { return Reg{ kind: .r16, idx: 5 } }
		'%si' { return Reg{ kind: .r16, idx: 6 } }
		'%di' { return Reg{ kind: .r16, idx: 7 } }
		'%r8w' { return Reg{ kind: .r16, idx: 8 } }
		'%r9w' { return Reg{ kind: .r16, idx: 9 } }
		'%r10w' { return Reg{ kind: .r16, idx: 10 } }
		'%r11w' { return Reg{ kind: .r16, idx: 11 } }
		'%r12w' { return Reg{ kind: .r16, idx: 12 } }
		'%r13w' { return Reg{ kind: .r16, idx: 13 } }
		'%r14w' { return Reg{ kind: .r16, idx: 14 } }
		'%r15w' { return Reg{ kind: .r16, idx: 15 } }
		'%al' { return Reg{ kind: .r8, idx: 0 } }
		'%cl' { return Reg{ kind: .r8, idx: 1 } }
		'%dl' { return Reg{ kind: .r8, idx: 2 } }
		'%bl' { return Reg{ kind: .r8, idx: 3 } }
		'%spl' { return Reg{ kind: .r8, idx: 4, rex8: true } }
		'%bpl' { return Reg{ kind: .r8, idx: 5, rex8: true } }
		'%sil' { return Reg{ kind: .r8, idx: 6, rex8: true } }
		'%dil' { return Reg{ kind: .r8, idx: 7, rex8: true } }
		'%r8b' { return Reg{ kind: .r8, idx: 8 } }
		'%r9b' { return Reg{ kind: .r8, idx: 9 } }
		'%r10b' { return Reg{ kind: .r8, idx: 10 } }
		'%r11b' { return Reg{ kind: .r8, idx: 11 } }
		'%r12b' { return Reg{ kind: .r8, idx: 12 } }
		'%r13b' { return Reg{ kind: .r8, idx: 13 } }
		'%r14b' { return Reg{ kind: .r8, idx: 14 } }
		'%r15b' { return Reg{ kind: .r8, idx: 15 } }
		else { return error('bad register "${s}"') }
	}
}

// --- byte helpers ---

fn modrm(mod int, reg int, rm int) u8 {
	return u8((mod << 6) | ((reg & 7) << 3) | (rm & 7))
}

// rex_byte builds the REX prefix. r and b are full register indices (or -1
// when the field holds an opcode extension). It returns -1 when no prefix
// is needed, matching GAS byte for byte: a bare 0x40 is never emitted.
fn rex_byte(w bool, r int, b int) int {
	need_r := r >= 8
	need_b := b >= 8
	if !w && !need_r && !need_b {
		return -1
	}
	mut v := 0x40
	if w {
		v |= 0x08
	}
	if need_r {
		v |= 0x04
	}
	if need_b {
		v |= 0x01
	}
	return v
}

// rex_byte_8 is rex_byte plus the spl/bpl/sil/dil rule: those four need a
// REX byte where ah-dh (rejected at parse) would not.
fn rex_byte_8(w bool, r Reg, b Reg) int {
	need := r.rex8 || b.rex8
	v := rex_byte(w, r.idx, b.idx)
	if v >= 0 || !need {
		return v
	}
	return 0x40
}

fn emit_rex(mut buf []u8, v int) {
	if v >= 0 {
		buf << u8(v)
	}
}

fn emit_u16(mut buf []u8, v int) {
	buf << u8(v & 0xff)
	buf << u8((v >> 8) & 0xff)
}

fn emit_u32(mut buf []u8, v i64) {
	for i in 0 .. 4 {
		buf << u8((v >> (u64(i) * 8)) & 0xff)
	}
}

fn emit_u64(mut buf []u8, v i64) {
	for i in 0 .. 8 {
		buf << u8((v >> (u64(i) * 8)) & 0xff)
	}
}

// emit_mem writes ModRM (+SIB, +displacement) for base+disp with reg_field in
// the reg bits. Indexed/SIB forms are rejected: fcc addresses everything as
// base+displacement, and a guessed SIB encoding would be a silent miscompile.
fn emit_mem(mut buf []u8, reg_field int, base int, disp int) {
	if disp == 0 && (base & 7) != 5 {
		buf << modrm(0, reg_field, base)
		if (base & 7) == 4 {
			buf << u8(0x24)
		}
	} else if disp >= -128 && disp <= 127 {
		buf << modrm(1, reg_field, base)
		if (base & 7) == 4 {
			buf << u8(0x24)
		}
		buf << u8(disp & 0xff)
	} else {
		buf << modrm(2, reg_field, base)
		if (base & 7) == 4 {
			buf << u8(0x24)
		}
		emit_u32(mut buf, i64(disp))
	}
}

// op_size ranks integer operand width for the plain-mnemonic size rule.
fn op_size_of(op Operand) int {
	return match op.kind {
		.reg {
			match op.reg.kind {
				.r64 { 64 }
				.r32 { 32 }
				.r16 { 16 }
				.r8 { 8 }
				.xmm { 0 }
			}
		}
		else { 0 }
	}
}

// int_size returns the effective width of a plain integer op (mov/add/...),
// or an error when neither operand names a width.
fn int_size(mn string, a Operand, b Operand, frag string) !int {
	sz := if op_size_of(a) >= op_size_of(b) { op_size_of(a) } else { op_size_of(b) }
	if sz == 0 {
		return error('cannot infer operand size for "${frag}"')
	}
	_ = mn
	return sz
}

fn emit_size_prefix(mut buf []u8, sz int, w_reg int, b_reg int, force_w bool) {
	if sz == 16 {
		buf << u8(0x66)
	}
	w := sz == 64 || force_w
	emit_rex(mut buf, rex_byte(w, w_reg, b_reg))
}

// --- the encoder ---

pub fn encode(mn string, ops []Operand, frag string, short_jump bool) !([]u8, []EncFixup) {
	mut buf := []u8{}
	mut fix := []EncFixup{}
	match mn {
		'push' {
			check_arity(ops, 1, frag)!
			if ops[0].kind == .reg {
				r := ops[0].reg
				if r.kind == .xmm {
					return error('cannot push "${frag}"')
				}
				if r.idx >= 8 {
					buf << u8(0x41)
				}
				buf << u8(0x50 + (r.idx & 7))
			} else if ops[0].kind == .imm {
				v := ops[0].imm
				if v >= -128 && v <= 127 {
					buf << u8(0x6a)
					buf << u8(v & 0xff)
				} else {
					buf << u8(0x68)
					emit_u32(mut buf, v)
				}
			} else {
				return error('cannot push "${frag}"')
			}
		}
		'pop' {
			check_arity(ops, 1, frag)!
			r := expect_reg(ops[0], frag)!
			if r.kind == .xmm {
				return error('cannot pop "${frag}"')
			}
			if r.idx >= 8 {
				buf << u8(0x41)
			}
			buf << u8(0x58 + (r.idx & 7))
		}
		'ret' {
			check_arity(ops, 0, frag)!
			buf << u8(0xc3)
		}
		'leave' {
			check_arity(ops, 0, frag)!
			buf << u8(0xc9)
		}
		'nop' {
			check_arity(ops, 0, frag)!
			buf << u8(0x90)
		}
		'syscall' {
			check_arity(ops, 0, frag)!
			buf << u8(0x0f)
			buf << u8(0x05)
		}
		'mov', 'movq' {
			encode_mov(mut buf, mn, ops, frag)!
		}
		'movsxd' {
			check_arity(ops, 2, frag)!
			src_is_mem := ops[0].kind == .mem
			dst := expect_reg(ops[1], frag)!
			if dst.kind != .r64 {
				return error('movsxd needs a 64-bit destination in "${frag}"')
			}
			if ops[0].kind == .reg && ops[0].reg.kind != .r32 {
				return error('movsxd needs a 32-bit source in "${frag}"')
			}
			if !src_is_mem && ops[0].kind != .reg {
				return error('bad movsxd source in "${frag}"')
			}
			src_idx := if src_is_mem { ops[0].base } else { ops[0].reg.idx }
			emit_rex(mut buf, rex_byte(true, dst.idx, src_idx))
			buf << u8(0x63)
			if src_is_mem {
				emit_mem(mut buf, dst.idx & 7, ops[0].base, ops[0].disp)
			} else {
				buf << modrm(3, dst.idx & 7, ops[0].reg.idx & 7)
			}
		}
		'movzb', 'movzx' {
			encode_zx(mut buf, u8(0xb6), ops, frag)!
		}
		'movzbl' {
			encode_zx(mut buf, u8(0xb6), ops, frag)!
		}
		'movsbl' {
			encode_zx(mut buf, u8(0xbe), ops, frag)!
		}
		'movswl', 'movzwl' {
			op := if mn == 'movswl' { u8(0xbf) } else { u8(0xb7) }
			encode_zx_word(mut buf, op, ops, frag)!
		}
		'lea' {
			check_arity(ops, 2, frag)!
			dst := expect_reg(ops[1], frag)!
			if dst.kind == .xmm || dst.kind == .r8 {
				return error('bad lea destination in "${frag}"')
			}
			if dst.kind == .r16 {
				buf << u8(0x66)
			}
			base_idx := if ops[0].kind == .mem { ops[0].base } else { -1 }
			emit_rex(mut buf, rex_byte(dst.kind == .r64, dst.idx, base_idx))
			buf << u8(0x8d)
			if ops[0].kind == .rip {
				buf << modrm(0, dst.idx & 7, 5)
				fix << rip_fixup(mut buf, ops[0].sym, 0)
			} else if ops[0].kind == .mem {
				emit_mem(mut buf, dst.idx & 7, ops[0].base, ops[0].disp)
			} else {
				return error('bad lea source in "${frag}"')
			}
		}
		'add', 'sub', 'cmp', 'and', 'or', 'xor', 'test' {
			encode_alu(mut buf, mn, ops, frag)!
		}
		'addl', 'subl', 'cmpl', 'andl', 'orl', 'xorl' {
			encode_alu_sized(mut buf, 32, mn, ops, frag)!
		}
		'addq', 'subq', 'cmpq', 'andq', 'orq', 'xorq' {
			encode_alu_sized(mut buf, 64, mn, ops, frag)!
		}
		'shl', 'shr', 'sar' {
			encode_shift(mut buf, mn, ops, frag)!
		}
		'imul' {
			check_arity(ops, 2, frag)!
			dst := expect_reg(ops[1], frag)!
			src_op := ops[0]
			sz := int_size(mn, src_op, ops[1], frag)!
			if sz != 32 && sz != 64 {
				return error('bad imul size in "${frag}"')
			}
			if dst.kind == .xmm || src_op.kind == .mem || src_op.reg.kind == .xmm {
				return error('unsupported imul form in "${frag}"')
			}
			if dst.kind == .r16 || src_op.reg.kind == .r16 {
				buf << u8(0x66)
			}
			rm_idx := src_op.reg.idx
			emit_rex(mut buf, rex_byte(sz == 64, dst.idx, rm_idx))
			buf << u8(0x0f)
			buf << u8(0xaf)
			buf << modrm(3, dst.idx & 7, src_op.reg.idx & 7)
		}
		'mul', 'div', 'idiv' {
			check_arity(ops, 1, frag)!
			ext := if mn == 'mul' {
				4
			} else if mn == 'div' {
				6
			} else {
				7
			}
			if ops[0].kind == .reg {
				r := ops[0].reg
				sz := op_size_of(ops[0])
				if r.kind == .xmm || (sz != 8 && sz != 16 && sz != 32 && sz != 64) {
					return error('bad ${mn} operand in "${frag}"')
				}
				if sz == 16 {
					buf << u8(0x66)
				}
				emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
				buf << u8(0xf7)
				buf << modrm(3, ext, r.idx & 7)
			} else if ops[0].kind == .mem {
				// Memory width is not knowable from the operand alone; the
				// plain form needs a register. Sized aliases do not exist for
				// div in this dialect, so this is a loud refusal.
				return error('cannot infer width of memory ${mn} in "${frag}"')
			} else {
				return error('bad ${mn} operand in "${frag}"')
			}
		}
		'cqo' {
			check_arity(ops, 0, frag)!
			buf << u8(0x48)
			buf << u8(0x99)
		}
		'cdq' {
			check_arity(ops, 0, frag)!
			buf << u8(0x99)
		}
		'neg', 'not', 'inc', 'dec' {
			check_arity(ops, 1, frag)!
			ext := if mn == 'neg' {
				3
			} else if mn == 'not' {
				2
			} else if mn == 'inc' {
				0
			} else {
				1
			}
			opcode := if mn in ['neg', 'not'] { u8(0xf7) } else { u8(0xff) }
			if ops[0].kind == .reg {
				r := ops[0].reg
				sz := op_size_of(ops[0])
				if r.kind == .xmm || sz == 0 {
					return error('bad ${mn} operand in "${frag}"')
				}
				if sz == 16 {
					buf << u8(0x66)
				}
				if sz == 8 {
					emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: ext }, r))
				} else {
					emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
				}
				buf << opcode
				buf << modrm(3, ext, r.idx & 7)
			} else if ops[0].kind == .mem {
				return error('cannot infer width of memory ${mn} in "${frag}"')
			} else {
				return error('bad ${mn} operand in "${frag}"')
			}
		}
		'jmp', 'je', 'jne', 'jl', 'jle', 'jg', 'jge', 'jb', 'jbe', 'ja', 'jae', 'js',
		'jns', 'jp', 'jnp', 'jo', 'jno' {
			encode_jump(mut buf, mut fix, mn, ops, frag, short_jump)!
		}
		'call' {
			check_arity(ops, 1, frag)!
			if ops[0].kind == .ireg {
				r := ops[0].reg
				if r.idx >= 8 {
					buf << u8(0x41)
				}
				buf << u8(0xff)
				buf << modrm(3, 2, r.idx & 7)
			} else if ops[0].kind == .sym {
				buf << u8(0xe8)
				fix << rel_fixup(mut buf, 4, ops[0].sym, .rel32, 0)
			} else {
				return error('bad call target in "${frag}"')
			}
		}
		'sete', 'setne', 'setl', 'setle', 'setg', 'setge', 'setb', 'setbe', 'seta',
		'setae', 'sets', 'setns', 'setp', 'setnp', 'seto', 'setno' {
			check_arity(ops, 1, frag)!
			r := expect_reg(ops[0], frag)!
			if r.kind != .r8 {
				return error('setcc needs an 8-bit register in "${frag}"')
			}
			cc := setcc_code(mn)!
			buf << u8(0x0f)
			buf << cc
			emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: 0 }, r))
			buf << modrm(3, 0, r.idx & 7)
		}
		'rep' {
			// `rep` only ever prefixes `stosb` in this dialect.
			check_arity(ops, 1, frag)!
			if ops[0].kind != .sym || ops[0].sym != 'stosb' {
				return error('unsupported rep prefix in "${frag}"')
			}
			buf << u8(0xf3)
			buf << u8(0xaa)
		}
		'movsd', 'movss' {
			encode_sse_mov(mut buf, mut fix, mn, ops, frag)!
		}
		'addsd', 'subsd', 'mulsd', 'divsd', 'addss', 'subss', 'mulss', 'divss',
		'ucomisd', 'ucomiss', 'xorpd', 'xorps', 'pxor' {
			encode_sse_alu(mut buf, mn, ops, frag)!
		}
		'cvtss2sd', 'cvtsd2ss', 'cvtsi2sd', 'cvtsi2ss', 'cvttsd2si', 'cvttss2si', 'cvtsi2sdl',
		'cvtsi2ssl', 'cvtsi2ssq', 'cvtsi2sdq', 'cvttsd2sil', 'cvttsd2siq', 'cvttss2sil',
		'cvttss2siq' {
			encode_sse_cvt(mut buf, cvt_base(mn), mn, ops, frag)!
		}
		'fldl', 'flds', 'frndint', 'fstpl', 'fstps', 'fistpl', 'fistpll', 'fldcw',
		'fnstcw' {
			encode_x87(mut buf, mn, ops, frag)!
		}
		else {
			return error('unsupported instruction "${mn}" in "${frag}"')
		}
	}
	return buf, fix
}

fn check_arity(ops []Operand, n int, frag string) ! {
	if ops.len != n {
		return error('wrong operand count in "${frag}"')
	}
}

fn expect_reg(op Operand, frag string) !Reg {
	if op.kind != .reg {
		return error('expected a register in "${frag}"')
	}
	return op.reg
}

// rip_fixup records a 4-byte RIP-relative reference at the buffer end.
fn rip_fixup(mut buf []u8, label string, addend int) EncFixup {
	at := buf.len
	for _ in 0 .. 4 {
		buf << u8(0)
	}
	return EncFixup{
		at:     at
		label:  label
		kind:   .rel32
		size:   4
		addend: addend
	}
}

fn rel_fixup(mut buf []u8, size int, label string, kind RelocKind, addend int) EncFixup {
	at := buf.len
	for _ in 0 .. size {
		buf << u8(0)
	}
	return EncFixup{
		at:     at
		label:  label
		kind:   kind
		size:   size
		addend: addend
	}
}

fn numref_fixup(mut buf []u8, label string, dir int, size int) EncFixup {
	at := buf.len
	for _ in 0 .. size {
		buf << u8(0)
	}
	return EncFixup{
		at:          at
		label:       label
		kind:        .rel32
		size:        size
		numeric_dir: dir
	}
}

// short_jcc_code is the 2-byte form GAS relaxes to (7x ib).
fn short_jcc_code(mn string) !u8 {
	return match mn {
		'jmp' { u8(0xeb) }
		'je' { u8(0x74) }
		'jne' { u8(0x75) }
		'jl' { u8(0x7c) }
		'jle' { u8(0x7e) }
		'jg' { u8(0x7f) }
		'jge' { u8(0x7d) }
		'jb' { u8(0x72) }
		'jbe' { u8(0x76) }
		'ja' { u8(0x77) }
		'jae' { u8(0x73) }
		'js' { u8(0x78) }
		'jns' { u8(0x79) }
		'jp' { u8(0x7a) }
		'jnp' { u8(0x7b) }
		'jo' { u8(0x70) }
		'jno' { u8(0x71) }
		else { return error('not a jump: ${mn}') }
	}
}

// --- mov ---

fn encode_mov(mut buf []u8, mn string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	src := ops[0]
	dst := ops[1]
	force_w := mn == 'movq'
	if src.kind == .rip || dst.kind == .rip {
		return error('rip-relative mov needs lea in "${frag}"')
	}
	if (src.kind == .reg && src.reg.kind == .xmm) || (dst.kind == .reg && dst.reg.kind == .xmm) {
		encode_movq_xmm(mut buf, src, dst, frag)!
		return
	}
	if src.kind == .imm && dst.kind == .reg {
		encode_mov_imm(mut buf, src.imm, dst, force_w, frag)!
		return
	}
	if src.kind == .reg && dst.kind == .reg {
		sz := int_size(mn, src, dst, frag)!
		if force_w && sz != 64 {
			return error('movq needs 64-bit operands in "${frag}"')
		}
		if src.reg.kind == .r8 || dst.reg.kind == .r8 {
			if (src.reg.kind != .r8 && src.reg.kind != .r64 && src.reg.kind != .r32 && src.reg.kind != .r16)
				|| (dst.reg.kind != .r8 && dst.reg.kind != .r64 && dst.reg.kind != .r32 && dst.reg.kind != .r16) {
				return error('bad mov operands in "${frag}"')
			}
			emit_rex(mut buf, rex_byte_8(false, src.reg, dst.reg))
			buf << u8(0x88)
			buf << modrm(3, src.reg.idx & 7, dst.reg.idx & 7)
			return
		}
		if sz == 16 {
			buf << u8(0x66)
		}
		emit_rex(mut buf, rex_byte(sz == 64, src.reg.idx, dst.reg.idx))
		buf << u8(0x89)
		buf << modrm(3, src.reg.idx & 7, dst.reg.idx & 7)
		return
	}
	if src.kind == .reg && dst.kind == .mem {
		sz := op_size_of(src)
		if force_w && sz != 64 {
			return error('movq needs 64-bit operands in "${frag}"')
		}
		if sz == 0 {
			return error('cannot infer operand size for "${frag}"')
		}
		if src.reg.kind == .r8 {
			emit_rex(mut buf, rex_byte_8(false, src.reg, Reg{ kind: .r32, idx: dst.base }))
			buf << u8(0x88)
			emit_mem(mut buf, src.reg.idx & 7, dst.base, dst.disp)
			return
		}
		if sz == 16 {
			buf << u8(0x66)
		}
		emit_rex(mut buf, rex_byte(sz == 64, src.reg.idx, dst.base))
		buf << u8(0x89)
		emit_mem(mut buf, src.reg.idx & 7, dst.base, dst.disp)
		return
	}
	if src.kind == .mem && dst.kind == .reg {
		sz := op_size_of(dst)
		if force_w && sz != 64 {
			return error('movq needs 64-bit operands in "${frag}"')
		}
		if sz == 0 {
			return error('cannot infer operand size for "${frag}"')
		}
		if dst.reg.kind == .r8 {
			emit_rex(mut buf, rex_byte_8(false, dst.reg, Reg{ kind: .r32, idx: src.base }))
			buf << u8(0x8a)
			emit_mem(mut buf, dst.reg.idx & 7, src.base, src.disp)
			return
		}
		if sz == 16 {
			buf << u8(0x66)
		}
		emit_rex(mut buf, rex_byte(sz == 64, dst.reg.idx, src.base))
		buf << u8(0x8b)
		emit_mem(mut buf, dst.reg.idx & 7, src.base, src.disp)
		return
	}
	if src.kind == .imm && dst.kind == .mem {
		// GAS needs an explicit width here; only movq occurs in this dialect.
		if !force_w {
			return error('cannot infer operand size for "${frag}"')
		}
		emit_rex(mut buf, rex_byte(true, 0, dst.base))
		buf << u8(0xc7)
		emit_mem(mut buf, 0, dst.base, dst.disp)
		emit_u32(mut buf, src.imm)
		return
	}
	return error('unsupported mov form in "${frag}"')
}

fn encode_mov_imm(mut buf []u8, v i64, dst Operand, force_w bool, frag string) ! {
	if dst.kind != .reg {
		return error('bad mov destination in "${frag}"')
	}
	r := dst.reg
	if r.kind == .xmm {
		return error('bad mov destination in "${frag}"')
	}
	if force_w && r.kind != .r64 {
		return error('movq needs 64-bit operands in "${frag}"')
	}
	match r.kind {
		.r64 {
			if v >= -2147483648 && v <= 2147483647 {
				emit_rex(mut buf, rex_byte(true, -1, r.idx))
				buf << u8(0xc7)
				buf << modrm(3, 0, r.idx & 7)
				emit_u32(mut buf, v)
			} else {
				emit_rex(mut buf, rex_byte(true, -1, r.idx))
				buf << u8(0xb8 + (r.idx & 7))
				emit_u64(mut buf, v)
			}
		}
		.r32 {
			emit_rex(mut buf, rex_byte(false, -1, r.idx))
			buf << u8(0xb8 + (r.idx & 7))
			emit_u32(mut buf, v)
		}
		.r16 {
			buf << u8(0x66)
			emit_rex(mut buf, rex_byte(false, -1, r.idx))
			buf << u8(0xb8 + (r.idx & 7))
			emit_u16(mut buf, int(v & 0xffff))
		}
		.r8 {
			emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: 0 }, r))
			buf << u8(0xb0 + (r.idx & 7))
			buf << u8(v & 0xff)
		}
		else {
			return error('bad mov destination in "${frag}"')
		}
	}
}

// encode_movq_xmm handles movq between a general register and an xmm register.
fn encode_movq_xmm(mut buf []u8, src Operand, dst Operand, frag string) ! {
	if src.kind == .reg && src.reg.kind == .r64 && dst.kind == .reg && dst.reg.kind == .xmm {
		buf << u8(0x66)
		emit_rex(mut buf, rex_byte(true, dst.reg.idx, src.reg.idx))
		buf << u8(0x0f)
		buf << u8(0x6e)
		buf << modrm(3, dst.reg.idx & 7, src.reg.idx & 7)
		return
	}
	if src.kind == .reg && src.reg.kind == .xmm && dst.kind == .reg && dst.reg.kind == .r64 {
		buf << u8(0x66)
		emit_rex(mut buf, rex_byte(true, src.reg.idx, dst.reg.idx))
		buf << u8(0x0f)
		buf << u8(0x7e)
		buf << modrm(3, src.reg.idx & 7, dst.reg.idx & 7)
		return
	}
	return error('unsupported movq form in "${frag}"')
}

// encode_zx handles movzb/movzx/movsbl (byte source, 0F B6/BE).
fn encode_zx(mut buf []u8, op u8, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	dst := expect_reg(ops[1], frag)!
	if ops[0].kind != .reg && ops[0].kind != .mem {
		return error('bad ${frag} source')
	}
	if ops[0].kind == .reg && ops[0].reg.kind != .r8 {
		return error('bad ${frag} source')
	}
	if dst.kind == .xmm || dst.kind == .r8 {
		return error('bad ${frag} destination')
	}
	if dst.kind == .r16 {
		buf << u8(0x66)
	}
	src_idx := if ops[0].kind == .reg { ops[0].reg.idx } else { -1 }
	src_rex8 := ops[0].kind == .reg && ops[0].reg.rex8
	_ = src_rex8
	if dst.kind == .r64 {
		emit_rex(mut buf, rex_byte(true, -1, dst.idx))
		if src_idx >= 8 {
			buf[buf.len - 1] |= 0x04
		}
		if src_rex8 {
			buf[buf.len - 1] |= 0x04
		}
	} else if dst.idx >= 8 || src_idx >= 8 || src_rex8 {
		mut v := 0x40
		if dst.idx >= 8 {
			v |= 0x01
		}
		if src_idx >= 8 || src_rex8 {
			v |= 0x04
		}
		buf << u8(v)
	}
	buf << u8(0x0f)
	buf << op
	if ops[0].kind == .mem {
		emit_mem(mut buf, dst.idx & 7, ops[0].base, ops[0].disp)
	} else {
		buf << modrm(3, dst.idx & 7, ops[0].reg.idx & 7)
	}
}

// encode_zx_word handles movswl/movzwl (word source, 0F BF/B7).
fn encode_zx_word(mut buf []u8, op u8, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	dst := expect_reg(ops[1], frag)!
	if ops[0].kind != .reg && ops[0].kind != .mem {
		return error('bad source in "${frag}"')
	}
	if ops[0].kind == .reg && ops[0].reg.kind != .r16 {
		return error('bad source in "${frag}"')
	}
	if dst.kind != .r32 && dst.kind != .r64 {
		return error('bad destination in "${frag}"')
	}
	src_idx := if ops[0].kind == .reg { ops[0].reg.idx } else { -1 }
	if dst.kind == .r64 {
		emit_rex(mut buf, rex_byte(true, -1, dst.idx))
		if src_idx >= 8 {
			buf[buf.len - 1] |= 0x04
		}
	} else if dst.idx >= 8 || src_idx >= 8 {
		mut v := 0x40
		if dst.idx >= 8 {
			v |= 0x01
		}
		if src_idx >= 8 {
			v |= 0x04
		}
		buf << u8(v)
	}
	buf << u8(0x0f)
	buf << op
	if ops[0].kind == .mem {
		emit_mem(mut buf, dst.idx & 7, ops[0].base, ops[0].disp)
	} else {
		buf << modrm(3, dst.idx & 7, ops[0].reg.idx & 7)
	}
}

// --- ALU ---

fn alu_ext(mn string) !int {
	return match mn {
		'add' { 0 }
		'or' { 1 }
		'and' { 4 }
		'sub' { 5 }
		'xor' { 6 }
		'cmp' { 7 }
		'test' { 0 }
		else { return error('not an ALU op: ${mn}') }
	}
}

fn alu_opcode(mn string, is_byte bool) u8 {
	if mn == 'test' {
		return if is_byte { u8(0x84) } else { u8(0x85) }
	}
	base := if is_byte { 0x00 } else { 0x01 }
	ext := match mn {
		'add' { 0 }
		'or' { 1 }
		'and' { 4 }
		'sub' { 5 }
		'xor' { 6 }
		'cmp' { 7 }
		else { 0 }
	}
	return u8(base + ext * 8)
}

fn encode_alu(mut buf []u8, mn string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	src := ops[0]
	dst := ops[1]
	if src.kind == .reg && dst.kind == .reg {
		if src.reg.kind == .xmm || dst.reg.kind == .xmm {
			return error('bad ${mn} operands in "${frag}"')
		}
		sz := int_size(mn, src, dst, frag)!
		is_byte := src.reg.kind == .r8 || dst.reg.kind == .r8
		if is_byte && (src.reg.kind != .r8 || dst.reg.kind != .r8) {
			// Mixed widths never occur; refuse rather than truncate.
			return error('mixed-width ${mn} in "${frag}"')
		}
		if mn == 'test' && src.kind == .reg && dst.kind == .reg {
			// test r,r is F7-less: 85 /r. Handled by the general path below
			// with the test opcode, which is exactly 84/85.
		}
		if sz == 16 && !is_byte {
			buf << u8(0x66)
		}
		if is_byte {
			emit_rex(mut buf, rex_byte_8(false, src.reg, dst.reg))
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, src.reg.idx, dst.reg.idx))
		}
		buf << alu_opcode(mn, is_byte)
		buf << modrm(3, src.reg.idx & 7, dst.reg.idx & 7)
		return
	}
	if src.kind == .imm && dst.kind == .reg {
		encode_alu_imm_reg(mut buf, mn, src.imm, dst.reg, frag)!
		return
	}
	if src.kind == .reg && dst.kind == .mem {
		if src.reg.kind == .xmm {
			return error('bad ${mn} operands in "${frag}"')
		}
		sz := op_size_of(src)
		if sz == 0 {
			return error('cannot infer operand size for "${frag}"')
		}
		is_byte := src.reg.kind == .r8
		if sz == 16 && !is_byte {
			buf << u8(0x66)
		}
		if is_byte {
			emit_rex(mut buf, rex_byte_8(false, src.reg, Reg{ kind: .r32, idx: dst.base }))
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, src.reg.idx, dst.base))
		}
		buf << alu_opcode(mn, is_byte)
		emit_mem(mut buf, src.reg.idx & 7, dst.base, dst.disp)
		return
	}
	if src.kind == .mem && dst.kind == .reg {
		if dst.reg.kind == .xmm {
			return error('bad ${mn} operands in "${frag}"')
		}
		sz := op_size_of(dst)
		if sz == 0 {
			return error('cannot infer operand size for "${frag}"')
		}
		is_byte := dst.reg.kind == .r8
		op := alu_opcode(mn, is_byte) + 2
		if sz == 16 && !is_byte {
			buf << u8(0x66)
		}
		if is_byte {
			emit_rex(mut buf, rex_byte_8(false, dst.reg, Reg{ kind: .r32, idx: src.base }))
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, dst.reg.idx, src.base))
		}
		buf << op
		emit_mem(mut buf, dst.reg.idx & 7, src.base, src.disp)
		return
	}
	if src.kind == .imm && dst.kind == .mem {
		return error('cannot infer width of memory ${mn} in "${frag}"')
	}
	return error('unsupported ${mn} form in "${frag}"')
}

// encode_alu_sized forces the width from a mnemonic suffix (addl/addq/...).
fn encode_alu_sized(mut buf []u8, sz int, mn string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	base := mn[..mn.len - 1]
	if ops[0].kind == .imm && ops[1].kind == .reg {
		r := ops[1].reg
		want := if sz == 64 { RegKind.r64 } else { RegKind.r32 }
		if r.kind != want {
			return error('width mismatch in "${frag}"')
		}
		encode_alu_imm_reg(mut buf, base, ops[0].imm, r, frag)!
		return
	}
	if ops[0].kind == .reg && ops[1].kind == .reg {
		// Reuse the plain path; the register widths must already carry the
		// suffix width (checked by int_size agreement inside).
		encode_alu(mut buf, base, ops, frag)!
		if op_size_of(ops[0]) != sz || op_size_of(ops[1]) != sz {
			return error('width mismatch in "${frag}"')
		}
		return
	}
	return error('unsupported ${mn} form in "${frag}"')
}

fn encode_alu_imm_reg(mut buf []u8, mn string, v i64, r Reg, frag string) ! {
	sz := match r.kind {
		.r64 { 64 }
		.r32 { 32 }
		.r16 { 16 }
		.r8 { 8 }
		.xmm { return error('bad ${mn} destination in "${frag}"') }
	}
	if mn == 'test' {
		if sz == 16 {
			buf << u8(0x66)
		}
		if sz == 8 {
			if r.idx == 0 && !r.rex8 {
				// test $imm, %al is A8 ib, exactly as GAS emits it.
				buf << u8(0xa8)
				buf << u8(v & 0xff)
			} else {
				emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: 0 }, r))
				buf << u8(0xf6)
				buf << modrm(3, 0, r.idx & 7)
				buf << u8(v & 0xff)
			}
		} else if (sz == 64 || sz == 32) && r.idx == 0 {
			// test $imm, %rax/%eax is A9 id, exactly as GAS emits it.
			emit_rex(mut buf, rex_byte(sz == 64, 0, 0))
			buf << u8(0xa9)
			emit_u32(mut buf, v)
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, 0, r.idx))
			buf << u8(0xf7)
			buf << modrm(3, 0, r.idx & 7)
			emit_u32(mut buf, v)
		}
		return
	}
	ext := alu_ext(mn)!
	// GAS wraps the immediate to 32 bits before choosing a form, so
	// $0xfffffff0 reads as -16 and takes the 83 form (orc5 oracle).
	mut sv := v & 0xffffffff
	if sv >= (i64(1) << 31) {
		sv -= i64(1) << 32
	}
	if sz == 8 {
		// GAS accumulator form for %al only (04+ext*8 ib); other byte
		// registers take the 80 form.
		if r.idx == 0 && !r.rex8 && v >= -128 && v <= 255 {
			buf << u8(0x04 + u8(ext * 8))
			buf << u8(v & 0xff)
			return
		}
		emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: ext }, r))
		buf << u8(0x80)
		buf << modrm(3, ext, r.idx & 7)
		buf << u8(v & 0xff)
		return
	}
	if sz == 16 {
		buf << u8(0x66)
	}
	if sv >= -128 && sv <= 127 {
		emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
		buf << u8(0x83)
		buf << modrm(3, ext, r.idx & 7)
		buf << u8(sv & 0xff)
		return
	}
	if (r.kind == .r32 || r.kind == .r64) && r.idx == 0 {
		// GAS accumulator form for %eax/%rax (05+ext*8 id, orc5 oracle).
		emit_rex(mut buf, rex_byte(sz == 64, 0, 0))
		buf << u8(0x05 + u8(ext * 8))
		emit_u32(mut buf, sv)
		return
	}
	emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
	buf << u8(0x81)
	buf << modrm(3, ext, r.idx & 7)
	emit_u32(mut buf, sv)
}

// --- shifts ---

fn encode_shift(mut buf []u8, mn string, ops []Operand, frag string) ! {
	ext := if mn == 'shl' {
		4
	} else if mn == 'shr' {
		5
	} else {
		7
	}
	if ops.len == 1 {
		// Single-operand `shr %rcx` shifts by one (D1 /ext), from the
		// uint64-to-double conversion sequence in gen.v.
		r := expect_reg(ops[0], frag)!
		if r.kind == .xmm {
			return error('bad shift destination in "${frag}"')
		}
		sz := op_size_of(ops[0])
		if sz == 0 {
			return error('cannot infer operand size for "${frag}"')
		}
		if sz == 16 {
			buf << u8(0x66)
		}
		if sz == 8 {
			emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: ext }, r))
			buf << u8(0xd0)
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
			buf << u8(0xd1)
		}
		buf << modrm(3, ext, r.idx & 7)
		return
	}
	check_arity(ops, 2, frag)!
	if ops[1].kind != .reg {
		return error('bad shift destination in "${frag}"')
	}
	r := ops[1].reg
	if r.kind == .xmm {
		return error('bad shift destination in "${frag}"')
	}
	sz := op_size_of(ops[1])
	if sz == 0 {
		return error('cannot infer operand size for "${frag}"')
	}
	if sz == 16 {
		buf << u8(0x66)
	}
	if ops[0].kind == .imm {
		v := ops[0].imm
		if sz == 8 {
			emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: ext }, r))
			if v == 1 {
				buf << u8(0xd0)
			} else {
				buf << u8(0xc0)
			}
			buf << modrm(3, ext, r.idx & 7)
			if v != 1 {
				buf << u8(v & 0xff)
			}
			return
		}
		if v == 1 {
			emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
			buf << u8(0xd1)
			buf << modrm(3, ext, r.idx & 7)
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
			buf << u8(0xc1)
			buf << modrm(3, ext, r.idx & 7)
			buf << u8(v & 0xff)
		}
		return
	}
	if ops[0].kind == .reg && ops[0].reg.kind == .r8 && ops[0].reg.idx == 1 {
		// shl/shr/sar %cl, reg
		if sz == 8 {
			emit_rex(mut buf, rex_byte_8(false, Reg{ kind: .r32, idx: ext }, r))
			buf << u8(0xd2)
			buf << modrm(3, ext, r.idx & 7)
		} else {
			emit_rex(mut buf, rex_byte(sz == 64, ext, r.idx))
			buf << u8(0xd3)
			buf << modrm(3, ext, r.idx & 7)
		}
		return
	}
	return error('bad shift count in "${frag}"')
}

// --- jumps ---

fn jcc_code(mn string) !u8 {
	return match mn {
		'jmp' { u8(0xe9) }
		'je' { u8(0x84) }
		'jne' { u8(0x85) }
		'jl' { u8(0x8c) }
		'jle' { u8(0x8e) }
		'jg' { u8(0x8f) }
		'jge' { u8(0x8d) }
		'jb' { u8(0x82) }
		'jbe' { u8(0x86) }
		'ja' { u8(0x87) }
		'jae' { u8(0x83) }
		'js' { u8(0x88) }
		'jns' { u8(0x89) }
		'jp' { u8(0x8a) }
		'jnp' { u8(0x8b) }
		'jo' { u8(0x80) }
		'jno' { u8(0x81) }
		else { return error('not a jump: ${mn}') }
	}
}

fn setcc_code(mn string) !u8 {
	return match mn {
		'sete' { u8(0x94) }
		'setne' { u8(0x95) }
		'setl' { u8(0x9c) }
		'setle' { u8(0x9e) }
		'setg' { u8(0x9f) }
		'setge' { u8(0x9d) }
		'setb' { u8(0x92) }
		'setbe' { u8(0x96) }
		'seta' { u8(0x97) }
		'setae' { u8(0x93) }
		'sets' { u8(0x98) }
		'setns' { u8(0x99) }
		'setp' { u8(0x9a) }
		'setnp' { u8(0x9b) }
		'seto' { u8(0x90) }
		'setno' { u8(0x91) }
		else { return error('not a setcc: ${mn}') }
	}
}

fn encode_jump(mut buf []u8, mut fix []EncFixup, mn string, ops []Operand, frag string, short_jump bool) ! {
	check_arity(ops, 1, frag)!
	code := jcc_code(mn)!
	if ops[0].kind == .ireg {
		if mn != 'jmp' {
			return error('conditional jump needs a label in "${frag}"')
		}
		r := ops[0].reg
		if r.idx >= 8 {
			buf << u8(0x41)
		}
		buf << u8(0xff)
		buf << modrm(3, 4, r.idx & 7)
		return
	}
	if short_jump {
		// 2-byte form, only for same-section labels (the sizing pass forces
		// near otherwise); the resolver refuses to relocate a 1-byte field.
		buf << short_jcc_code(mn)!
		if ops[0].kind == .sym {
			fix << rel_fixup(mut buf, 1, ops[0].sym, .rel32, 0)
		} else if ops[0].kind == .numref {
			fix << numref_fixup(mut buf, ops[0].sym, ops[0].numdir, 1)
		} else {
			return error('bad jump target in "${frag}"')
		}
		return
	}
	if mn == 'jmp' {
		buf << u8(0xe9)
	} else {
		buf << u8(0x0f)
		buf << code
	}
	if ops[0].kind == .sym {
		fix << rel_fixup(mut buf, 4, ops[0].sym, .rel32, 0)
	} else if ops[0].kind == .numref {
		fix << numref_fixup(mut buf, ops[0].sym, ops[0].numdir, 4)
	} else {
		return error('bad jump target in "${frag}"')
	}
}

// --- SSE ---

fn encode_sse_mov(mut buf []u8, mut fix []EncFixup, mn string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	is_sd := mn == 'movsd'
	pre := if is_sd { u8(0xf2) } else { u8(0xf3) }
	src := ops[0]
	dst := ops[1]
	if src.kind == .reg && src.reg.kind == .xmm && dst.kind == .reg && dst.reg.kind == .xmm {
		buf << pre
		emit_rex(mut buf, rex_byte(false, src.reg.idx, dst.reg.idx))
		buf << u8(0x0f)
		buf << u8(0x10)
		buf << modrm(3, dst.reg.idx & 7, src.reg.idx & 7)
		return
	}
	if src.kind == .mem && dst.kind == .reg && dst.reg.kind == .xmm {
		// load m64/m32 -> xmm
		buf << pre
		emit_rex(mut buf, rex_byte(false, dst.reg.idx, src.base))
		buf << u8(0x0f)
		buf << u8(0x10)
		emit_mem(mut buf, dst.reg.idx & 7, src.base, src.disp)
		return
	}
	if src.kind == .reg && src.reg.kind == .xmm && dst.kind == .mem {
		// store xmm -> m64/m32
		buf << pre
		emit_rex(mut buf, rex_byte(false, src.reg.idx, dst.base))
		buf << u8(0x0f)
		buf << u8(0x11)
		emit_mem(mut buf, src.reg.idx & 7, dst.base, dst.disp)
		return
	}
	if src.kind == .rip && dst.kind == .reg && dst.reg.kind == .xmm {
		// load rip-relative -> xmm (constant pools, if the backend emits them).
		buf << pre
		emit_rex(mut buf, rex_byte(false, dst.reg.idx, -1))
		buf << u8(0x0f)
		buf << u8(0x10)
		buf << modrm(0, dst.reg.idx & 7, 5)
		fix << rip_fixup(mut buf, src.sym, 0)
		at := fix[fix.len - 1].at
		_ = at
		return
	}
	return error('unsupported ${mn} form in "${frag}"')
}

fn encode_sse_alu(mut buf []u8, mn string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	src := expect_reg(ops[0], frag)!
	dst := expect_reg(ops[1], frag)!
	if src.kind != .xmm || dst.kind != .xmm {
		return error('SSE ALU needs xmm registers in "${frag}"')
	}
	pre, op := match mn {
		'addsd' { u8(0xf2), u8(0x58) }
		'subsd' { u8(0xf2), u8(0x5c) }
		'mulsd' { u8(0xf2), u8(0x59) }
		'divsd' { u8(0xf2), u8(0x5e) }
		'addss' { u8(0xf3), u8(0x58) }
		'subss' { u8(0xf3), u8(0x5c) }
		'mulss' { u8(0xf3), u8(0x59) }
		'divss' { u8(0xf3), u8(0x5e) }
		'ucomisd' { u8(0x66), u8(0x2e) }
		'ucomiss' { u8(0x00), u8(0x2e) }
		'xorpd' { u8(0x66), u8(0x57) }
		'xorps' { u8(0x00), u8(0x57) }
		'pxor' { u8(0x66), u8(0xef) }
		else { return error('not an SSE ALU op: ${mn}') }
	}
	if pre != 0 {
		buf << pre
	}
	emit_rex(mut buf, rex_byte(false, dst.idx, src.idx))
	buf << u8(0x0f)
	buf << op
	buf << modrm(3, dst.idx & 7, src.idx & 7)
}

// cvt_base strips the AT&T size suffix from integer conversions:
// cvtsi2sdl reads a 32-bit int, cvtsi2ssq a 64-bit one.
fn cvt_base(mn string) string {
	for base in ['cvtsi2sd', 'cvtsi2ss', 'cvttsd2si', 'cvttss2si'] {
		if mn.starts_with(base) {
			return base
		}
	}
	return mn
}

// encode_sse_cvt handles cvtss2sd/cvtsd2ss/cvtsi2sd/cvtsi2ss/cvttsd2si/cvttss2si.
fn encode_sse_cvt(mut buf []u8, base string, full string, ops []Operand, frag string) ! {
	check_arity(ops, 2, frag)!
	int_src := base.starts_with('cvtsi') || base.starts_with('cvtts')
	if !int_src {
		// xmm -> xmm conversions.
		src := expect_reg(ops[0], frag)!
		dst := expect_reg(ops[1], frag)!
		if src.kind != .xmm || dst.kind != .xmm {
			return error('bad ${base} operands in "${frag}"')
		}
		pre := if base == 'cvtss2sd' { u8(0xf3) } else { u8(0xf2) }
		buf << pre
		emit_rex(mut buf, rex_byte(false, dst.idx, src.idx))
		buf << u8(0x0f)
		buf << u8(0x5a)
		buf << modrm(3, dst.idx & 7, src.idx & 7)
		return
	}
	is_trunc := base.starts_with('cvtt')
	// is_ss names the conversion width (ss reads/writes 4 bytes), not a
	// mnemonic suffix: cvttss2si ends in `si` but converts from ss.
	is_ss := base in ['cvtss2sd', 'cvtsi2ss', 'cvttss2si']
	pre := if is_ss { u8(0xf3) } else { u8(0xf2) }
	op := if is_trunc { u8(0x2c) } else { u8(0x2a) }
	// The AT&T suffix on the full mnemonic (cvtsi2sdl vs cvtsi2ssq) must
	// agree with the integer register width.
	sfx := full[base.len..]
	if !is_trunc {
		// cvtsi2sd/ss: int -> xmm.
		dst := expect_reg(ops[1], frag)!
		if dst.kind != .xmm {
			return error('bad ${base} destination in "${frag}"')
		}
		if ops[0].kind == .reg {
			src := ops[0].reg
			if src.kind != .r32 && src.kind != .r64 {
				return error('bad ${base} source in "${frag}"')
			}
			if (sfx == 'l' && src.kind != .r32) || (sfx == 'q' && src.kind != .r64) {
				return error('width mismatch in "${frag}"')
			}
			w := src.kind == .r64
			buf << pre
			emit_rex(mut buf, rex_byte(w, dst.idx, src.idx))
			buf << u8(0x0f)
			buf << op
			buf << modrm(3, dst.idx & 7, src.idx & 7)
			return
		}
		if ops[0].kind == .mem {
			// Width comes from the conversion: ss reads 4 bytes, sd reads 8.
			// The memory operand carries no width, so the mnemonic decides.
			buf << pre
			emit_rex(mut buf, rex_byte(false, dst.idx, ops[0].base))
			buf << u8(0x0f)
			buf << op
			emit_mem(mut buf, dst.idx & 7, ops[0].base, ops[0].disp)
			return
		}
		return error('bad ${base} source in "${frag}"')
	}
	// cvttsd/ss2si: xmm -> int.
	src := expect_reg(ops[0], frag)!
	if src.kind != .xmm {
		return error('bad ${base} source in "${frag}"')
	}
	if ops[1].kind != .reg {
		return error('bad ${base} destination in "${frag}"')
	}
	dst := ops[1].reg
	if dst.kind != .r32 && dst.kind != .r64 {
		return error('bad ${base} destination in "${frag}"')
	}
	if (sfx == 'l' && dst.kind != .r32) || (sfx == 'q' && dst.kind != .r64) {
		return error('width mismatch in "${frag}"')
	}
	w := dst.kind == .r64
	buf << pre
	emit_rex(mut buf, rex_byte(w, dst.idx, src.idx))
	buf << u8(0x0f)
	buf << op
	buf << modrm(3, dst.idx & 7, src.idx & 7)
}

// --- x87 ---

fn encode_x87(mut buf []u8, mn string, ops []Operand, frag string) ! {
	if mn == 'frndint' {
		check_arity(ops, 0, frag)!
		buf << u8(0xd9)
		buf << u8(0xfc)
		return
	}
	check_arity(ops, 1, frag)!
	if ops[0].kind != .mem {
		return error('x87 ${mn} needs a memory operand in "${frag}"')
	}
	op, ext := match mn {
		'fldl' { u8(0xdd), 0 }
		'flds' { u8(0xd9), 0 }
		'fstpl' { u8(0xdd), 3 }
		'fstps' { u8(0xd9), 3 }
		'fistpl' { u8(0xdb), 3 }
		'fistpll' { u8(0xdf), 7 }
		'fldcw' { u8(0xd9), 5 }
		'fnstcw' { u8(0xd9), 7 }
		else { return error('not an x87 op: ${mn}') }
	}
	buf << op
	emit_mem(mut buf, ext, ops[0].base, ops[0].disp)
}
