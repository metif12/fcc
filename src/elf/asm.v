module elf

// x86-64 instruction encoder for fcc's backend.
// Encodes the most common instructions fcc generates.

pub const reg_rax = 0
pub const reg_rcx = 1
pub const reg_rdx = 2
pub const reg_rbx = 3
pub const reg_rsp = 4
pub const reg_rbp = 5
pub const reg_rsi = 6
pub const reg_rdi = 7
pub const reg_r8 = 8
pub const reg_r9 = 9
pub const reg_r10 = 10
pub const reg_r11 = 11
pub const reg_r12 = 12
pub const reg_r13 = 13
pub const reg_r14 = 14
pub const reg_r15 = 15

fn reg_name(r int) string {
	names := ['%rax', '%rcx', '%rdx', '%rbx', '%rsp', '%rbp', '%rsi', '%rdi', '%r8', '%r9', '%r10',
		'%r11', '%r12', '%r13', '%r14', '%r15']
	if r >= 0 && r < names.len { return names[r] }
	return ''
}

// REX prefix helper
fn rex(w bool, r int, x int, b int) u8 {
	mut v := u8(0x40)
	if w { v |= 0x08 }
	if r >= 8 { v |= 0x04 }
	if x >= 8 { v |= 0x02 }
	if b >= 8 { v |= 0x01 }
	if v != 0x40 { return v }
	return 0
}

// ModRM byte
fn modrm(mod int, reg int, rm int) u8 {
	return u8((mod << 6) | ((reg & 7) << 3) | (rm & 7))
}

// Encode push reg
pub fn enc_push(reg int) []u8 {
	if reg < 8 {
		return [u8(0x50 + reg)]
	}
	return [u8(0x41), u8(0x50 + (reg - 8))]
}

// Encode pop reg
pub fn enc_pop(reg int) []u8 {
	if reg < 8 {
		return [u8(0x58 + reg)]
	}
	return [u8(0x41), u8(0x58 + (reg - 8))]
}

// Encode ret
pub fn enc_ret() []u8 {
	return [u8(0xc3)]
}

// Encode nop
pub fn enc_nop() []u8 {
	return [u8(0x90)]
}

// Encode leave
pub fn enc_leave() []u8 {
	return [u8(0xc9)]
}

// Encode syscall
pub fn enc_syscall() []u8 {
	return [u8(0x0f), u8(0x05)]
}

// Encode mov imm64 -> reg
pub fn enc_mov_imm64(reg int, imm i64) []u8 {
	mut buf := []u8{}
	r := rex(true, 0, 0, reg)
	if r != 0 { buf << r }
	buf << u8(0xb8 + (reg & 7))
	for i in 0 .. 8 {
		buf << u8((imm >> (i * 8)) & 0xff)
	}
	return buf
}

// Encode mov reg -> reg
pub fn enc_mov_rr(src int, dst int) []u8 {
	mut buf := []u8{}
	r := rex(true, src, 0, dst)
	if r != 0 { buf << r }
	buf << u8(0x89)
	buf << modrm(3, src, dst)
	return buf
}

// Encode mov reg -> mem (base + offset)
pub fn enc_mov_rm(src int, base int, offset int) []u8 {
	mut buf := []u8{}
	r := rex(true, src, 0, base)
	if r != 0 { buf << r }
	buf << u8(0x89)
	// ModRM with mod=01 (8-bit disp) or 10 (32-bit disp) or 00 (no disp)
	if offset == 0 && (base & 7) != 5 {
		buf << modrm(0, src, base)
		if (base & 7) == 4 {
			buf << u8(0x24) // SIB
		}
	} else if offset >= -128 && offset <= 127 {
		buf << modrm(1, src, base)
		if (base & 7) == 4 {
			buf << u8(0x24)
		}
		buf << u8(offset & 0xff)
	} else {
		buf << modrm(2, src, base)
		if (base & 7) == 4 {
			buf << u8(0x24)
		}
		for i in 0 .. 4 {
			buf << u8((offset >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode mov mem -> reg
pub fn enc_mov_mr(base int, offset int, dst int) []u8 {
	mut buf := []u8{}
	r := rex(true, dst, 0, base)
	if r != 0 { buf << r }
	buf << u8(0x8b)
	if offset == 0 && (base & 7) != 5 {
		buf << modrm(0, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
	} else if offset >= -128 && offset <= 127 {
		buf << modrm(1, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
		buf << u8(offset & 0xff)
	} else {
		buf << modrm(2, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
		for i in 0 .. 4 {
			buf << u8((offset >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode add imm -> reg
pub fn enc_add_imm(reg int, imm i64) []u8 {
	mut buf := []u8{}
	if imm >= -128 && imm <= 127 {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x83)
		buf << modrm(3, 0, reg)
		buf << u8(imm & 0xff)
	} else {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x81)
		buf << modrm(3, 0, reg)
		for i in 0 .. 4 {
			buf << u8((imm >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode sub imm -> reg
pub fn enc_sub_imm(reg int, imm i64) []u8 {
	mut buf := []u8{}
	if imm >= -128 && imm <= 127 {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x83)
		buf << modrm(3, 5, reg)
		buf << u8(imm & 0xff)
	} else {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x81)
		buf << modrm(3, 5, reg)
		for i in 0 .. 4 {
			buf << u8((imm >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode cmp reg, reg
pub fn enc_cmp_rr(src int, dst int) []u8 {
	mut buf := []u8{}
	r := rex(true, src, 0, dst)
	if r != 0 { buf << r }
	buf << u8(0x39)
	buf << modrm(3, src, dst)
	return buf
}

// Encode cmp imm, reg
pub fn enc_cmp_imm(reg int, imm i64) []u8 {
	mut buf := []u8{}
	if imm >= -128 && imm <= 127 {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x83)
		buf << modrm(3, 7, reg)
		buf << u8(imm & 0xff)
	} else {
		r := rex(true, 0, 0, reg)
		if r != 0 { buf << r }
		buf << u8(0x81)
		buf << modrm(3, 7, reg)
		for i in 0 .. 4 {
			buf << u8((imm >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode lea (base + offset) -> reg
pub fn enc_lea(base int, offset int, dst int) []u8 {
	mut buf := []u8{}
	r := rex(true, dst, 0, base)
	if r != 0 { buf << r }
	buf << u8(0x8d)
	if offset == 0 && (base & 7) != 5 {
		buf << modrm(0, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
	} else if offset >= -128 && offset <= 127 {
		buf << modrm(1, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
		buf << u8(offset & 0xff)
	} else {
		buf << modrm(2, dst, base)
		if (base & 7) == 4 { buf << u8(0x24) }
		for i in 0 .. 4 {
			buf << u8((offset >> (i * 8)) & 0xff)
		}
	}
	return buf
}

// Encode jmp rel32 (relative offset)
pub fn enc_jmp_rel(offset int) []u8 {
	mut buf := []u8{}
	buf << u8(0xe9)
	for i in 0 .. 4 {
		buf << u8((offset >> (i * 8)) & 0xff)
	}
	return buf
}

// Encode jcc (conditional jump) rel32
pub fn enc_jcc(cond u8, offset int) []u8 {
	mut buf := []u8{}
	buf << u8(0x0f)
	buf << cond
	for i in 0 .. 4 {
		buf << u8((offset >> (i * 8)) & 0xff)
	}
	return buf
}

// Condition codes
pub const cc_je = u8(0x84)
pub const cc_jne = u8(0x85)
pub const cc_jl = u8(0x8c)
pub const cc_jle = u8(0x8e)
pub const cc_jg = u8(0x8f)
pub const cc_jge = u8(0x8d)
pub const cc_jb = u8(0x82)
pub const cc_jbe = u8(0x86)
pub const cc_ja = u8(0x87)
pub const cc_jae = u8(0x83)

// Encode call reg (indirect)
pub fn enc_call_reg(reg int) []u8 {
	mut buf := []u8{}
	if reg >= 8 {
		buf << u8(0x41)
	}
	buf << u8(0xff)
	buf << modrm(3, 2, reg)
	return buf
}

// Encode call rel32 (direct, relative)
pub fn enc_call_rel(offset int) []u8 {
	mut buf := []u8{}
	buf << u8(0xe8)
	for i in 0 .. 4 {
		buf << u8((offset >> (i * 8)) & 0xff)
	}
	return buf
}

// Encode a function that returns 0
pub fn encode_return_zero() []u8 {
	mut buf := []u8{}
	// mov $60, %rax (exit syscall)
	b1 := enc_mov_imm64(reg_rax, 60)
	for b in b1 { buf << b }
	// mov $0, %rdi (exit code 0)
	b2 := enc_mov_imm64(reg_rdi, 0)
	for b in b2 { buf << b }
	// syscall
	b3 := enc_syscall()
	for b in b3 { buf << b }
	result := buf
	return result
}

// Helper to append slices
fn append_bytes(mut dst []u8, src []u8) {
	for b in src {
		dst << b
	}
}
