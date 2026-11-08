module elf

// Native x86-64 assembler for fcc's generated assembly.
// Parses fcc's text assembly and produces machine code bytes.

pub fn assemble(text string) ![]u8 {
	mut code := []u8{}
	mut labels := map[string]int{}
	mut fixups := []Fixup{}
	lines := text.split('\n')

	for line in lines {
		trimmed := line.trim_space()
		if trimmed == '' { continue }
		if trimmed.starts_with('.') { continue }
		if trimmed.ends_with(':') {
			label := trimmed[..trimmed.len - 1]
			labels[label] = code.len
		}
	}

	for line in lines {
		trimmed := line.trim_space()
		if trimmed == '' { continue }
		if trimmed.starts_with('.') { continue }
		if trimmed.ends_with(':') { continue }
		encode_line(mut code, mut fixups, trimmed) or {
			eprintln('FAIL: ${trimmed}')
			return error('unsupported: ${trimmed}')
		}
	}

	for fixup in fixups {
		if label_pos := labels[fixup.label] {
			rel := label_pos - (fixup.offset + 4)
			for i in 0 .. 4 {
				code[fixup.offset + i] = u8((rel >> (i * 8)) & 0xff)
			}
		}
	}
	return code
}

struct Fixup {
pub mut:
	offset int
	label  string
}

fn encode_line(mut code []u8, mut fixups []Fixup, instr string) ! {
	parts := instr.split(' ')
	op := parts[0]
	if op == 'push' {
		reg := parse_reg(parts[1])
		if reg < 8 {
			code << u8(0x50 + reg)
		} else {
			code << u8(0x41)
			code << u8(0x50 + (reg - 8))
		}
	} else if op == 'pop' {
		reg := parse_reg(parts[1])
		if reg < 8 {
			code << u8(0x58 + reg)
		} else {
			code << u8(0x41)
			code << u8(0x58 + (reg - 8))
		}
	} else if op == 'ret' {
		code << u8(0xc3)
	} else if op == 'nop' {
		code << u8(0x90)
	} else if op == 'leave' {
		code << u8(0xc9)
	} else if op == 'syscall' {
		code << u8(0x0f)
		code << u8(0x05)
	} else if op == 'mov' {
		encode_mov(mut code, parts)
	} else if op == 'movq' {
		encode_mov(mut code, parts)
	} else if op == 'movl' {
		encode_mov(mut code, parts)
	} else if op == 'movsxd' {
		// movsxd mem, reg
		src := parts[1].trim_right(',')
		dst := parts[2]
		base, offset := parse_mem(src)
		dst_reg := parse_reg(dst)
		mut rex := u8(0x48)
		if dst_reg >= 8 { rex = rex | 0x04 }
		if base >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x63)
		emit_modrm_mem(mut code, dst_reg & 7, base, offset)
	} else if op == 'movzb' {
		code << u8(0x0f)
		code << u8(0xb6)
		code << u8(0xc0)
	} else if op == 'movdqa' {
		encode_movdqa(mut code, parts)
	} else if op == 'lea' {
		encode_lea(mut code, parts)
	} else if op == 'add' {
		encode_add(mut code, parts)
	} else if op == 'addl' {
		encode_addl(mut code, parts)
	} else if op == 'addq' {
		encode_addq(mut code, parts)
	} else if op == 'sub' {
		encode_sub(mut code, parts)
	} else if op == 'cmp' {
		encode_cmp(mut code, parts)
	} else if op == 'cmpl' {
		encode_cmpl(mut code, parts)
	} else if op == 'jmp' {
		label := parts[1]
		code << u8(0xe9)
		fixups << Fixup{ offset: code.len, label: label }
		for _ in 0 .. 4 { code << u8(0) }
	} else if op == 'je' {
		code << u8(0x0f)
		code << u8(0x84)
		label := parts[1]
		fixups << Fixup{ offset: code.len, label: label }
		for _ in 0 .. 4 { code << u8(0) }
	} else if op == 'jge' {
		code << u8(0x0f)
		code << u8(0x8d)
		label := parts[1]
		fixups << Fixup{ offset: code.len, label: label }
		for _ in 0 .. 4 { code << u8(0) }
	} else if op == 'call' {
		label := parts[1]
		if label.starts_with('*') {
			reg := parse_reg(label[1..])
			if reg >= 8 {
				code << u8(0x41)
			}
			code << u8(0xff)
			code << u8(0xd0 | (reg & 7))
		} else {
			code << u8(0xe8)
			fixups << Fixup{ offset: code.len, label: label }
			for _ in 0 .. 4 { code << u8(0) }
		}
	} else if op == 'sete' {
		code << u8(0x0f)
		code << u8(0x94)
		code << u8(0xc0)
	} else if op == 'setl' {
		code << u8(0x0f)
		code << u8(0x9c)
		code << u8(0xc0)
	} else if op == 'rep' {
		code << u8(0xf3)
		code << u8(0xaa)
	} else {
		return error('unknown op: ${op}')
	}
}

fn encode_mov(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		reg := parse_reg(dst)
		if imm >= -2147483648 && imm <= 2147483647 {
			// Use 32-bit immediate form (sign-extended): 48 c7 c0 <imm32>
			mut rex := u8(0x48)
			if reg >= 8 { rex = rex | 0x01 }
			if rex != 0 { code << rex }
			code << u8(0xc7)
			code << u8(0xc0 | (reg & 7))
			for i in 0 .. 4 {
				code << u8((imm >> (i * 8)) & 0xff)
			}
		} else {
			if reg >= 8 {
				code << u8(0x49)
			} else {
				code << u8(0x48)
			}
			code << u8(0xb8 + (reg & 7))
			for i in 0 .. 8 {
				code << u8((imm >> (i * 8)) & 0xff)
			}
		}
	} else if src.starts_with('%') && dst.starts_with('%') {
		src_reg := parse_reg(src)
		dst_reg := parse_reg(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if dst_reg >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x89)
		code << u8(0xc0 | ((src_reg & 7) << 3) | (dst_reg & 7))
	} else if src.starts_with('%') {
		src_reg := parse_reg(src)
		base, offset := parse_mem(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if base >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x89)
		emit_modrm_mem(mut code, src_reg & 7, base, offset)
	} else if dst.starts_with('%') {
		base, offset := parse_mem(src)
		dst_reg := parse_reg(dst)
		mut rex := u8(0x48)
		if dst_reg >= 8 { rex = rex | 0x04 }
		if base >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x8b)
		emit_modrm_mem(mut code, dst_reg & 7, base, offset)
	}
}

fn encode_lea(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	base, offset := parse_mem(src)
	dst_reg := parse_reg(dst)
	mut rex := u8(0x48)
	if dst_reg >= 8 { rex = rex | 0x04 }
	if base >= 8 { rex = rex | 0x01 }
	code << rex
	code << u8(0x8d)
	emit_modrm_mem(mut code, dst_reg & 7, base, offset)
}

fn encode_add(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		reg := parse_reg(dst)
		if imm >= -128 && imm <= 127 {
			mut rex := u8(0x48)
			if reg >= 8 { rex = rex | 0x01 }
			code << rex
			code << u8(0x83)
			code << u8(0xc0 | (reg & 7))
			code << u8(imm & 0xff)
		} else {
			mut rex := u8(0x48)
			if reg >= 8 { rex = rex | 0x01 }
			code << rex
			code << u8(0x81)
			code << u8(0xc0 | (reg & 7))
			for i in 0 .. 4 {
				code << u8((imm >> (i * 8)) & 0xff)
			}
		}
	} else if src.starts_with('%') && dst.starts_with('%') {
		src_reg := parse_reg(src)
		dst_reg := parse_reg(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if dst_reg >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x01)
		code << u8(0xc0 | ((src_reg & 7) << 3) | (dst_reg & 7))
	} else if src.starts_with('%') {
		src_reg := parse_reg(src)
		base, offset := parse_mem(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if base >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x01)
		emit_modrm_mem(mut code, src_reg & 7, base, offset)
	}
}

fn encode_sub(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		reg := parse_reg(dst)
		if imm >= -128 && imm <= 127 {
			mut rex := u8(0x48)
			if reg >= 8 { rex = rex | 0x01 }
			code << rex
			code << u8(0x83)
			code << u8(0xe8 | (reg & 7))
			code << u8(imm & 0xff)
		} else {
			mut rex := u8(0x48)
			if reg >= 8 { rex = rex | 0x01 }
			code << rex
			code << u8(0x81)
			code << u8(0xe8 | (reg & 7))
			for i in 0 .. 4 {
				code << u8((imm >> (i * 8)) & 0xff)
			}
		}
	}
}

fn encode_cmp(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		if dst.starts_with('%') {
			reg := parse_reg(dst)
			if imm >= -128 && imm <= 127 {
				mut rex := u8(0x48)
				if reg >= 8 { rex = rex | 0x01 }
				code << rex
				code << u8(0x83)
				code << u8(0xf8 | (reg & 7))
				code << u8(imm & 0xff)
			} else {
				mut rex := u8(0x48)
				if reg >= 8 { rex = rex | 0x01 }
				code << rex
				code << u8(0x81)
				code << u8(0xf8 | (reg & 7))
				for i in 0 .. 4 {
					code << u8((imm >> (i * 8)) & 0xff)
				}
			}
		}
	} else if src.starts_with('%') && dst.starts_with('%') {
		src_reg := parse_reg(src)
		dst_reg := parse_reg(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if dst_reg >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x39)
		code << u8(0xc0 | ((src_reg & 7) << 3) | (dst_reg & 7))
	}
}

fn encode_addl(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		base, offset := parse_mem(dst)
		mut rex := u8(0x40)
		if base >= 8 { rex = rex | 0x01 }
		if rex != 0x40 { code << rex }
		code << u8(0x81)
		code << u8(0x00 | (base & 7))
		emit_modrm_mem(mut code, 0, base, offset)
		for i in 0 .. 4 {
			code << u8((imm >> (i * 8)) & 0xff)
		}
	}
}

fn encode_addq(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		base, offset := parse_mem(dst)
		if imm >= -128 && imm <= 127 {
			mut rex := u8(0x48)
			if base >= 8 { rex = rex | 0x01 }
			code << rex
			code << u8(0x83)
			code << u8(0x00 | (base & 7))
			emit_modrm_mem_simple(mut code, base, offset)
			code << u8(imm & 0xff)
		}
	} else if src.starts_with('%') {
		src_reg := parse_reg(src)
		base, offset := parse_mem(dst)
		mut rex := u8(0x48)
		if src_reg >= 8 { rex = rex | 0x04 }
		if base >= 8 { rex = rex | 0x01 }
		code << rex
		code << u8(0x01)
		emit_modrm_mem(mut code, src_reg & 7, base, offset)
	}
}

fn encode_cmpl(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('$') {
		imm := parse_imm(src[1..])
		base, offset := parse_mem(dst)
		mut rex := u8(0x40)
		if base >= 8 { rex = rex | 0x01 }
		if rex != 0x40 { code << rex }
		code << u8(0x81)
		code << u8(0x38 | (base & 7))
		emit_modrm_mem_simple(mut code, base, offset)
		for i in 0 .. 4 {
			code << u8((imm >> (i * 8)) & 0xff)
		}
	}
}

fn encode_movdqa(mut code []u8, parts []string) {
	src := parts[1].trim_right(',')
	dst := parts[2]
	if src.starts_with('%') {
		reg := parse_xmm(src)
		base, offset := parse_mem(dst)
		code << u8(0x66)
		mut rex := u8(0x40)
		if base >= 8 { rex = rex | 0x01 }
		if rex != 0x40 { code << rex }
		code << u8(0x0f)
		code << u8(0x7f)
		emit_modrm_mem(mut code, reg & 7, base, offset)
	} else if dst.starts_with('%') {
		base, offset := parse_mem(src)
		reg := parse_xmm(dst)
		code << u8(0x66)
		mut rex := u8(0x40)
		if base >= 8 { rex = rex | 0x01 }
		if rex != 0x40 { code << rex }
		code << u8(0x0f)
		code << u8(0x6f)
		emit_modrm_mem(mut code, reg & 7, base, offset)
	}
}

fn emit_modrm_mem(mut code []u8, reg int, base int, offset int) {
	if offset == 0 && (base & 7) != 5 {
		code << u8((reg << 3) | (base & 7))
		if (base & 7) == 4 {
			code << u8(0x24)
		}
	} else if offset >= -128 && offset <= 127 {
		code << u8(0x40 | ((reg & 7) << 3) | (base & 7))
		if (base & 7) == 4 {
			code << u8(0x24)
		}
		code << u8(offset & 0xff)
	} else {
		code << u8(0x80 | ((reg & 7) << 3) | (base & 7))
		if (base & 7) == 4 {
			code << u8(0x24)
		}
		for i in 0 .. 4 {
			code << u8((offset >> (i * 8)) & 0xff)
		}
	}
}

fn emit_modrm_mem_simple(mut code []u8, base int, offset int) {
	emit_modrm_mem(mut code, 0, base, offset)
}

fn parse_reg(s string) int {
	mut s2 := s.trim_space()
	if s2 == '%rax' { return 0 }
	if s2 == '%rcx' { return 1 }
	if s2 == '%rdx' { return 2 }
	if s2 == '%rbx' { return 3 }
	if s2 == '%rsp' { return 4 }
	if s2 == '%rbp' { return 5 }
	if s2 == '%rsi' { return 6 }
	if s2 == '%rdi' { return 7 }
	if s2 == '%r8' { return 8 }
	if s2 == '%r9' { return 9 }
	if s2 == '%r10' { return 10 }
	if s2 == '%r11' { return 11 }
	if s2 == '%r12' { return 12 }
	if s2 == '%r13' { return 13 }
	if s2 == '%r14' { return 14 }
	if s2 == '%r15' { return 15 }
	if s2 == '%eax' { return 0 }
	if s2 == '%ecx' { return 1 }
	if s2 == '%edx' { return 2 }
	if s2 == '%ebx' { return 3 }
	if s2 == '%esi' { return 6 }
	if s2 == '%edi' { return 7 }
	if s2 == '%al' { return 0 }
	if s2 == '%cl' { return 1 }
	if s2 == '%dl' { return 2 }
	if s2 == '%bl' { return 3 }
	return -1
}

fn parse_xmm(s string) int {
	mut s2 := s.trim_space()
	if s2.starts_with('%xmm') {
		return s2[5..].int()
	}
	return -1
}

fn parse_mem(s string) (int, int) {
	mut s2 := s.trim_space()
	if s2.contains('(') {
		parts := s2.split('(')
		offset_str := parts[0]
		reg_str := parts[1].replace(')', '').trim_space()
		offset := if offset_str == '' { 0 } else { offset_str.int() }
		return parse_reg(reg_str), offset
	}
	return -1, 0
}

fn parse_imm(s string) i64 {
	mut s2 := s.trim_space()
	if s2.starts_with('$') { s2 = s2[1..] }
	return s2.i64()
}
