module coff

import os
import src.masm

// COFF object writer for phase 3 (x86-64 Windows objects).
//
// The layout mirrors what GNU as emits for the same input (measured with
// objdump on s1/v probe objects, not recalled):
//
//   [20B file header][nsec*40B section headers][raw .text][raw .data]
//   [relocs][symtab][string table]
//
// Conventions copied from GAS: section order .text/.data/.bss, characteristics
// 0x60500020/0xC0500040/0xC0500080, raw sections padded to 16 bytes, File and
// section symbols with one aux record each, no aux for functions, type 0
// everywhere, file characteristics 0x4 with relocations / 0x5 without.

// NumberOfRelocations is u16; 0xFFFF means the real count lives in the first
// relocation's VirtualAddress (IMAGE_SCN_LNK_NRELOC_OVFL).
const max_direct_relocs = 0xfffe

const file_magic_amd64 = u16(0x8664)

const scn_text_chars = u32(0x60500020)
const scn_data_chars = u32(0xc0500040)
const scn_bss_chars = u32(0xc0500080)

const rel_addr64 = u16(1)
const rel_addr32 = u16(2)
const rel_rel32 = u16(4)

const sym_undef = u16(0)
const sym_debug = i16(-2)
const class_external = u8(2)
const class_static = u8(3)
const class_file = u8(103)

// write_object assembles nothing itself: `out` comes from `masm.assemble`
// and this only serializes it.
pub fn write_object(out masm.AsmOut, path string) ! {
	mut w := Writer{
		out: out
	}
	w.build_symbols()
	w.layout()!
	w.emit_header()
	w.emit_sections()
	w.emit_raw()
	w.emit_relocs()
	w.emit_symtab()
	w.emit_strtab()
	w.patch_header()
	os.write_file(path, w.buf.bytestr()) or { return error('cannot write ${path}') }
}

struct CoffSymbol {
	name      string
	value     int
	section   int
	is_extern bool
	is_file   bool
	is_sect   bool
	aux       []u8
}

struct Writer {
mut:
	out  masm.AsmOut
	buf  []u8
	syms []CoffSymbol
	// rec_idx maps a symbol name to its COFF symbol-table record index,
	// which counts aux records: file=0, .text=2, .data=4, .bss=6, then
	// user symbols from 8 upward (they carry no aux).
	rec_idx map[string]int
	sym_idx map[string]int
	strtab  []u8
	stroff  map[string]int
	// layout results
	raw_text_at    int
	raw_data_at    int
	rel_text_at    int
	rel_data_at    int
	symtab_at      int
	strtab_at      int
	shoff          int
	text_nrel      int
	data_nrel      int
	head_chars_off int
}

fn (mut w Writer) build_symbols() {
	// Symbol 0 is the File symbol, exactly as GAS emits for `.file "vcc"`.
	mut aux := []u8{len: 18}
	fname := if w.out.file_name == '' { 'vcc' } else { w.out.file_name }
	for i in 0 .. 18 {
		if i < fname.len {
			aux[i] = fname[i]
		}
	}
	w.syms << CoffSymbol{ name: '.file', is_file: true, aux: aux }
	w.rec_idx['.file'] = 0
	// Section symbols live at records 2, 4, 6 (each followed by one aux
	// record). scnlen is the UNPADDED section size; the aux also carries
	// the section's relocation count, as GAS emits.
	sec_sizes := [w.out.text_len, w.out.data_len, w.out.bss_size]
	sec_nrels := [w.out.text_relocs.len, w.out.data_relocs.len, 0]
	mut rec := 2
	for i, sec in [1, 2, 3] {
		mut sa := []u8{len: 18}
		// IMAGE_AUX_SYMBOL section record: Length[0], NumberOfRelocations[4].
		put_u32_at(mut sa, 0, u32(sec_sizes[i]))
		put_u16_at(mut sa, 4, u16(sec_nrels[i]))
		w.syms << CoffSymbol{
			name:    section_name(sec)
			section: sec
			is_sect: true
			aux:     sa
		}
		w.rec_idx[section_name(sec)] = rec
		rec += 2
	}
	for s in w.out.symbols {
		if s.name in w.sym_idx {
			continue
		}
		w.sym_idx[s.name] = w.syms.len
		w.rec_idx[s.name] = rec
		rec++
		w.syms << CoffSymbol{
			name:      s.name
			value:     s.offset
			section:   s.section
			is_extern: s.is_global
		}
	}
	// String table entries for names longer than 8 bytes.
	w.strtab << u8(0)
	for s in w.syms {
		if s.name.len > 8 && !(s.name in w.stroff) {
			w.stroff[s.name] = w.strtab.len
			for c in s.name {
				w.strtab << c
			}
			w.strtab << u8(0)
		}
	}
}

fn section_name(sec int) string {
	return match sec {
		1 { '.text' }
		2 { '.data' }
		else { '.bss' }
	}
}

fn (mut w Writer) layout() ! {
	nsec := 3
	w.shoff = 20
	w.raw_text_at = w.shoff + nsec * 40
	w.raw_data_at = w.raw_text_at + w.out.text.len
	w.rel_text_at = w.raw_data_at + w.out.data.len
	w.text_nrel = w.out.text_relocs.len
	w.data_nrel = w.out.data_relocs.len
	if w.text_nrel > max_direct_relocs || w.data_nrel > max_direct_relocs {
		return error('too many relocations for a COFF object')
	}
	w.rel_data_at = w.rel_text_at + w.text_nrel * 10
	w.symtab_at = w.rel_data_at + w.data_nrel * 10
	// The string table length field counts itself.
	str_len := w.strtab.len + 4
	_ = str_len
}

fn (mut w Writer) emit_header() {
	put_u16(mut w.buf, file_magic_amd64)
	put_u16(mut w.buf, 3) // NumberOfSections
	put_u32(mut w.buf, 0) // TimeDateStamp
	put_u32(mut w.buf, 0) // PointerToSymbolTable (patched later)
	put_u32(mut w.buf, 0) // NumberOfSymbols (patched later)
	put_u16(mut w.buf, 0) // SizeOfOptionalHeader
	w.head_chars_off = w.buf.len
	put_u16(mut w.buf, 0) // Characteristics (patched later)
}

fn (mut w Writer) emit_sections() {
	w.emit_section('.text', 0, w.out.text.len, w.raw_text_at, w.rel_text_at, w.text_nrel,
		scn_text_chars)
	w.emit_section('.data', 0, w.out.data.len, w.raw_data_at, w.rel_data_at, w.data_nrel,
		scn_data_chars)
	// .bss carries no raw bytes, so VirtualSize is its only size; without it
	// the loader allocates nothing and zero-init globals read garbage.
	w.emit_section('.bss', w.out.bss_size, 0, 0, 0, 0, scn_bss_chars)
}

fn (mut w Writer) emit_section(name string, vsize int, rawsz int, rawptr int, relptr int, nrel int, chars u32) {
	mut nm := []u8{len: 8}
	for i in 0 .. 8 {
		if i < name.len {
			nm[i] = name[i]
		}
	}
	w.buf << nm
	put_u32(mut w.buf, u32(vsize)) // VirtualSize (real size only for .bss)
	put_u32(mut w.buf, 0) // VirtualAddress
	put_u32(mut w.buf, u32(rawsz))
	put_u32(mut w.buf, u32(rawptr))
	put_u32(mut w.buf, u32(relptr))
	put_u32(mut w.buf, 0) // PointerToLinenumbers
	put_u16(mut w.buf, u16(nrel))
	put_u16(mut w.buf, 0) // NumberOfLinenumbers
	put_u32(mut w.buf, chars)
}

fn (mut w Writer) emit_raw() {
	for w.buf.len < w.raw_text_at {
		w.buf << u8(0)
	}
	w.buf << w.out.text
	for w.buf.len < w.raw_data_at {
		w.buf << u8(0)
	}
	w.buf << w.out.data
}

fn (mut w Writer) sym_index(name string) int {
	// Section names resolve to the section symbols' record indices
	// (2/4/6: each section symbol is followed by its aux record).
	if name == '.text' {
		return 2
	}
	if name == '.data' {
		return 4
	}
	if name == '.bss' {
		return 6
	}
	return w.rec_idx[name] or { 0 }
}

fn reloc_type(k masm.RelocKind) u16 {
	return match k {
		.rel32 { rel_rel32 }
		.addr64 { rel_addr64 }
		.addr32 { rel_addr32 }
	}
}

fn (mut w Writer) emit_relocs() {
	for w.buf.len < w.rel_text_at {
		w.buf << u8(0)
	}
	for r in w.out.text_relocs {
		put_u32(mut w.buf, u32(r.offset))
		put_u32(mut w.buf, u32(w.sym_index(r.symbol)))
		put_u16(mut w.buf, reloc_type(r.kind))
	}
	for r in w.out.data_relocs {
		put_u32(mut w.buf, u32(r.offset))
		put_u32(mut w.buf, u32(w.sym_index(r.symbol)))
		put_u16(mut w.buf, reloc_type(r.kind))
	}
}

fn (mut w Writer) emit_symtab() {
	for w.buf.len < w.symtab_at {
		w.buf << u8(0)
	}
	for s in w.syms {
		w.emit_symbol(s)
	}
}

fn (mut w Writer) emit_symbol(s CoffSymbol) {
	if s.name.len > 8 {
		put_u32(mut w.buf, 0)
		put_u32(mut w.buf, u32(w.stroff[s.name] or { 0 } + 4))
	} else {
		mut nm := []u8{len: 8}
		for i in 0 .. 8 {
			if i < s.name.len {
				nm[i] = s.name[i]
			}
		}
		w.buf << nm
	}
	put_u32(mut w.buf, u32(s.value))
	if s.is_file {
		put_u16(mut w.buf, u16(sym_debug))
	} else {
		put_u16(mut w.buf, u16(s.section))
	}
	put_u16(mut w.buf, 0) // Type
	if s.is_file {
		w.buf << class_file
	} else if s.is_sect {
		w.buf << class_static
	} else if s.is_extern {
		w.buf << class_external
	} else {
		w.buf << class_static
	}
	if s.aux.len > 0 {
		w.buf << u8(1)
		w.buf << s.aux
	} else {
		w.buf << u8(0)
	}
}

fn (mut w Writer) emit_strtab() {
	w.strtab_at = w.buf.len
	put_u32(mut w.buf, u32(w.strtab.len + 4))
	w.buf << w.strtab
}

fn (mut w Writer) patch_header() {
	put_u32_at(mut w.buf, 8, u32(w.symtab_at))
	mut nsym := 0
	for s in w.syms {
		nsym += 1
		if s.aux.len > 0 {
			nsym += 1
		}
	}
	put_u32_at(mut w.buf, 12, u32(nsym))
	has_rel := w.text_nrel > 0 || w.data_nrel > 0
	chars := if has_rel { u16(0x4) } else { u16(0x5) }
	put_u16_at(mut w.buf, w.head_chars_off, chars)
}

// --- little-endian writers ---

fn put_u16(mut buf []u8, v u16) {
	buf << u8(v & 0xff)
	buf << u8((v >> 8) & 0xff)
}

fn put_u32(mut buf []u8, v u32) {
	for i in 0 .. 4 {
		buf << u8((v >> (u32(i) * 8)) & 0xff)
	}
}

fn put_u16_at(mut buf []u8, at int, v u16) {
	buf[at] = u8(v & 0xff)
	buf[at + 1] = u8((v >> 8) & 0xff)
}

fn put_u32_at(mut buf []u8, at int, v u32) {
	for i in 0 .. 4 {
		buf[at + i] = u8((v >> (u32(i) * 8)) & 0xff)
	}
}
