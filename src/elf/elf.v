module elf

import os

// ELF64 constants
const sht_progbits = 1
const sht_symtab = 2
const sht_strtab = 3
const sht_rela = 4

// ELF64 relocatable object writer.
// Produces a valid ELF64 ET_REL file with .text, .symtab, .strtab, .shstrtab.

pub struct Section {
pub mut:
	name  string
	data  []u8
	align int
}

pub struct Symbol {
pub mut:
	name  string
	value int
	size  int
	info  u8
	shndx int
}

pub struct Relocation {
pub mut:
	offset int
	sym    int
	type_  int
	addend int
}

pub struct ObjectWriter {
pub mut:
	sections []Section
	symbols  []Symbol
	strtab   []u8
	shstrtab []u8
	rela     []Relocation
	text_idx int
}

pub fn new_object_writer() ObjectWriter {
	mut w := ObjectWriter{}
	// Section 0 is always NULL.
	w.sections << Section{ name: '', data: [], align: 0 }
	// .text section (index 1)
	w.text_idx = 1
	w.sections << Section{ name: '.text', data: [], align: 16 }
	return w
}

pub fn (mut w ObjectWriter) add_text(data []u8) {
	w.sections[1].data = data
}

pub fn (mut w ObjectWriter) add_symbol(name string, value int, size int, info u8, shndx int) int {
	w.symbols << Symbol{ name: name, value: value, size: size, info: info, shndx: shndx }
	return w.symbols.len - 1
}

pub fn (mut w ObjectWriter) add_relocation(offset int, sym int, type_ int, addend int) {
	w.rela << Relocation{ offset: offset, sym: sym, type_: type_, addend: addend }
}

// write_object produces a valid ELF64 relocatable object.
pub fn (w ObjectWriter) write_object(path string) ! {
	mut buf := []u8{}

	// Build string tables
	mut strtab := []u8{}
	strtab << u8(0) // null byte
	mut str_offsets := map[string]int{}
	for sym in w.symbols {
		str_offsets[sym.name] = strtab.len
		for c in sym.name {
			strtab << u8(c)
		}
		strtab << u8(0)
	}

	mut shstrtab := []u8{}
	shstrtab << u8(0)
	// Collect section names
	mut section_name_offsets := []int{}
	for sec in w.sections {
		section_name_offsets << shstrtab.len
		for c in sec.name {
			shstrtab << u8(c)
		}
		shstrtab << u8(0)
	}
	// Add .symtab, .strtab, .shstrtab, .rela.text names
	symtab_name_off := shstrtab.len
	for c in '.symtab' { shstrtab << u8(c) }
	shstrtab << u8(0)
	strtab_name_off := shstrtab.len
	for c in '.strtab' { shstrtab << u8(c) }
	shstrtab << u8(0)
	shstrtab_name_off := shstrtab.len
	for c in '.shstrtab' { shstrtab << u8(c) }
	shstrtab << u8(0)
	rela_name_off := shstrtab.len
	for c in '.rela.text' { shstrtab << u8(c) }
	shstrtab << u8(0)

	// Calculate offsets
	// Section data starts after ELF header + section headers (placeholder)
	// We'll do two passes: first calculate sizes, then write.

	// Section indices:
	// 0: NULL
	// 1: .text
	// 2: .symtab
	// 3: .strtab
	// 4: .shstrtab
	// 5: .rela.text (if relocations exist)

	num_sections := 5 + if w.rela.len > 0 { 1 } else { 0 }

	// ELF header (64 bytes)
	buf << u8(0x7f)
	buf << u8(0x45)
	buf << u8(0x4c)
	buf << u8(0x46)
	buf << u8(2) // ELFCLASS64
	buf << u8(1) // ELFDATA2LSB
	buf << u8(1) // EV_CURRENT
	buf << u8(0) // OS/ABI
	buf << u8(0) // ABI version
	for _ in 0 .. 7 { buf << u8(0) } // padding

	buf << u8(1)
	buf << u8(0) // e_type = ET_REL
	buf << u8(62)
	buf << u8(0) // e_machine = EM_X86_64
	buf << u8(1)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0) // e_version
	for _ in 0 .. 8 { buf << u8(0) } // e_entry
	for _ in 0 .. 8 { buf << u8(0) } // e_phoff
	// e_shoff placeholder
	shoff_pos := buf.len
	for _ in 0 .. 8 { buf << u8(0) }
	for _ in 0 .. 4 { buf << u8(0) } // e_flags
	buf << u8(64)
	buf << u8(0) // e_ehsize
	buf << u8(0)
	buf << u8(0) // e_phentsize
	buf << u8(0)
	buf << u8(0) // e_phnum
	buf << u8(64)
	buf << u8(0) // e_shentsize
	shnum_pos := buf.len
	buf << u8(num_sections)
	buf << u8(0) // e_shnum
	buf << u8(4)
	buf << u8(0) // e_shstrndx = 4 (.shstrtab)

	// Now write section data
	// .text section data starts at offset 64 (after ELF header)
	// .symtab, .strtab, etc. follow

	// Calculate sizes
	text_size := w.sections[1].data.len
	// .symtab: 24 bytes per symbol (Elf64_Sym)
	symtab_size := (w.symbols.len + 1) * 24 // +1 for null symbol
	strtab_size := strtab.len
	shstrtab_size := shstrtab.len
	rela_size := w.rela.len * 24 // Elf64_Rela is 24 bytes

	// Offsets
	text_off := 64
	symtab_off := text_off + text_size
	// Align to 8
	symtab_off_aligned := if symtab_off % 8 != 0 {
		symtab_off + (8 - symtab_off % 8)
	} else {
		symtab_off
	}
	strtab_off := symtab_off_aligned + symtab_size
	shstrtab_off := strtab_off + strtab_size
	rela_off := shstrtab_off + shstrtab_size
	rela_off_aligned := if rela_off % 8 != 0 { rela_off + (8 - rela_off % 8) } else { rela_off }

	// Write .text
	for buf.len < text_off {
		buf << u8(0)
	}
	for b in w.sections[1].data {
		buf << b
	}

	// Pad to symtab_off
	for buf.len < symtab_off_aligned {
		buf << u8(0)
	}

	// Write .symtab (null symbol first)
	for _ in 0 .. 24 { buf << u8(0) } // null symbol
	for sym in w.symbols {
		// st_name (4 bytes)
		name_off := str_offsets[sym.name]
		for i in 0 .. 4 {
			buf << u8((name_off >> (i * 8)) & 0xff)
		}
		// st_info (1 byte)
		buf << sym.info
		// st_other (1 byte)
		buf << u8(0)
		// st_shndx (2 bytes)
		buf << u8(sym.shndx & 0xff)
		buf << u8((sym.shndx >> 8) & 0xff)
		// st_value (8 bytes)
		for i in 0 .. 8 {
			buf << u8((sym.value >> (i * 8)) & 0xff)
		}
		// st_size (8 bytes)
		for i in 0 .. 8 {
			buf << u8((sym.size >> (i * 8)) & 0xff)
		}
	}

	// Write .strtab
	for buf.len < strtab_off {
		buf << u8(0)
	}
	for b in strtab {
		buf << b
	}

	// Write .shstrtab
	for buf.len < shstrtab_off {
		buf << u8(0)
	}
	for b in shstrtab {
		buf << b
	}

	// Write .rela.text (if any)
	if w.rela.len > 0 {
		for buf.len < rela_off_aligned {
			buf << u8(0)
		}
		for rel in w.rela {
			// r_offset (8 bytes)
			for i in 0 .. 8 {
				buf << u8((rel.offset >> (i * 8)) & 0xff)
			}
			// r_info (8 bytes): (sym << 32) | type
			r_info := (u64(rel.sym) << 32) | u64(rel.type_)
			for i in 0 .. 8 {
				buf << u8((r_info >> (i * 8)) & 0xff)
			}
			// r_addend (8 bytes)
			for i in 0 .. 8 {
				buf << u8((rel.addend >> (i * 8)) & 0xff)
			}
		}
	}

	// Now write section headers
	// Align to 8
	for buf.len % 8 != 0 {
		buf << u8(0)
	}
	shoff := buf.len

	// Section 0: NULL
	for _ in 0 .. 64 { buf << u8(0) }

	// Section 1: .text
	write_section_header(mut buf, section_name_offsets[1], sht_progbits, 0x6, text_off, text_size, 0, 0, 16, 0)
	// Section 2: .symtab
	write_section_header(mut buf, symtab_name_off, sht_symtab, 0, symtab_off_aligned, symtab_size, 3, 1, 8, 24)
	// Section 3: .strtab
	write_section_header(mut buf, strtab_name_off, sht_strtab, 0, strtab_off, strtab_size, 0, 0, 1, 0)
	// Section 4: .shstrtab
	write_section_header(mut buf, shstrtab_name_off, sht_strtab, 0, shstrtab_off, shstrtab_size, 0, 0, 1, 0)
	// Section 5: .rela.text (if relocations)
	if w.rela.len > 0 {
		write_section_header(mut buf, rela_name_off, sht_rela, 0, rela_off_aligned, rela_size, 2, 1, 8, 24)
	}

	// Patch e_shoff in ELF header
	for i in 0 .. 8 {
		buf[shoff_pos + i] = u8((shoff >> (i * 8)) & 0xff)
	}
	// Patch e_shnum
	buf[shnum_pos] = u8(num_sections & 0xff)
	buf[shnum_pos + 1] = u8((num_sections >> 8) & 0xff)

	os.write_file(path, buf.bytestr()) or { return error('cannot write ${path}') }
}

fn write_section_header(mut buf []u8, name_off int, type_ int, flags int, offset int, size int, link int, info int, align int, entsize int) {
	for i in 0 .. 4 {
		buf << u8((name_off >> (i * 8)) & 0xff)
	}
	for i in 0 .. 4 {
		buf << u8((type_ >> (i * 8)) & 0xff)
	}
	for i in 0 .. 8 {
		buf << u8((flags >> (i * 8)) & 0xff)
	}
	for i in 0 .. 8 {
		buf << u8((offset >> (i * 8)) & 0xff)
	}
	for i in 0 .. 8 {
		buf << u8((size >> (i * 8)) & 0xff)
	}
	for i in 0 .. 4 {
		buf << u8((link >> (i * 8)) & 0xff)
	}
	for i in 0 .. 4 {
		buf << u8((info >> (i * 8)) & 0xff)
	}
	for i in 0 .. 8 {
		buf << u8((align >> (i * 8)) & 0xff)
	}
	for i in 0 .. 8 {
		buf << u8((entsize >> (i * 8)) & 0xff)
	}
}

// write_exit0 produces a minimal ELF64 executable that exits with code 0.
pub fn write_exit0(path string) ! {
	code := [u8(0x48), u8(0xc7), u8(0xc0), u8(60), u8(0), u8(0), u8(0), u8(0x48), u8(0xc7), u8(0xc7),
		u8(0), u8(0), u8(0), u8(0), u8(0x0f), u8(0x05)]
	write_executable(path, code)!
}

pub fn write_executable(path string, code []u8) ! {
	mut buf := []u8{}

	buf << u8(0x7f)
	buf << u8(0x45)
	buf << u8(0x4c)
	buf << u8(0x46)
	buf << u8(2)
	buf << u8(1)
	buf << u8(1)
	buf << u8(0)
	buf << u8(0)
	for _ in 0 .. 7 { buf << u8(0) }

	buf << u8(2)
	buf << u8(0) // e_type
	buf << u8(62)
	buf << u8(0) // e_machine
	buf << u8(1)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0) // e_version
	entry := u64(0x400000 + 0x78)
	for i in 0 .. 8 { buf << u8((entry >> (i * 8)) & 0xff) }
	for i in 0 .. 8 { buf << u8((u64(64) >> (i * 8)) & 0xff) } // e_phoff
	for _ in 0 .. 8 { buf << u8(0) } // e_shoff
	for _ in 0 .. 4 { buf << u8(0) } // e_flags
	buf << u8(64)
	buf << u8(0) // e_ehsize
	buf << u8(56)
	buf << u8(0) // e_phentsize
	buf << u8(1)
	buf << u8(0) // e_phnum
	buf << u8(0)
	buf << u8(0) // e_shentsize
	buf << u8(0)
	buf << u8(0) // e_shnum
	buf << u8(0)
	buf << u8(0) // e_shstrndx

	// Program header
	buf << u8(1)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0) // p_type
	buf << u8(5)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0) // p_flags
	for _ in 0 .. 8 { buf << u8(0) } // p_offset
	for i in 0 .. 8 { buf << u8((u64(0x400000) >> (i * 8)) & 0xff) } // p_vaddr
	for i in 0 .. 8 { buf << u8((u64(0x400000) >> (i * 8)) & 0xff) } // p_paddr
	filesz := u64(0x78 + code.len)
	for i in 0 .. 8 { buf << u8((filesz >> (i * 8)) & 0xff) }
	for i in 0 .. 8 { buf << u8((filesz >> (i * 8)) & 0xff) }
	buf << u8(0)
	buf << u8(0x10)
	for _ in 0 .. 6 { buf << u8(0) }

	for buf.len < 0x78 { buf << u8(0) }
	for b in code { buf << b }

	os.write_file(path, buf.bytestr()) or { return error('cannot write ${path}') }
}
