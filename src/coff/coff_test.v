module coff

import os
import src.masm

// Structural tests: write an object, read the headers back with plain V
// code, and assert the GAS-matching conventions (magic, section order and
// characteristics, symbol classes, relocation entries).

const scratch = 'coff_test_tmp'

struct CoffView {
pub mut:
	chars    u16
	nsec     int
	nsym     int
	sections []CoffSection
	relocs   []CoffReloc
	syms     []CoffSym
}

struct CoffSection {
	name  string
	vsize int
	rawsz int
	chars u32
	nrel  int
}

struct CoffReloc {
	off   int
	sym   int
	type_ int
}

struct CoffSym {
	name    string
	value   int
	section int
	class   u8
	has_aux bool
	// rec is the COFF symbol-table record index (counting aux records),
	// which is what relocation entries point at.
	rec int
	// aux0/aux6 are the first and seventh aux words (scnlen, nreloc).
	aux0 int
	aux4 int
	aux6 int
}

fn read_u16(b []u8, at int) u16 {
	return u16(b[at]) | (u16(b[at + 1]) << 8)
}

fn read_u32(b []u8, at int) u32 {
	return u32(b[at]) | (u32(b[at + 1]) << 8) | (u32(b[at + 2]) << 16) | (u32(b[at + 3]) << 24)
}

fn view_object(path string) CoffView {
	raw := os.read_file(path) or { panic('cannot read ${path}: ${err.msg()}') }.bytes()
	mut v := CoffView{}
	assert read_u16(raw, 0) == 0x8664
	v.nsec = int(read_u16(raw, 2))
	assert v.nsec == 3
	symptr := int(read_u32(raw, 8))
	v.nsym = int(read_u32(raw, 12))
	assert read_u16(raw, 16) == 0
	v.chars = read_u16(raw, 18)
	for i in 0 .. v.nsec {
		o := 20 + i * 40
		mut nm := ''
		for j in 0 .. 8 {
			if raw[o + j] == 0 {
				break
			}
			nm += raw[o + j].ascii_str()
		}
		relptr := int(read_u32(raw, o + 24))
		nrel := int(read_u16(raw, o + 32))
		v.sections << CoffSection{nm, int(read_u32(raw, o + 8)), int(read_u32(raw, o + 16)), read_u32(raw,
			o + 36), nrel}
		rel_bytes := raw[relptr..relptr + nrel * 10]
		for k in 0 .. nrel {
			ro := k * 10
			v.relocs << CoffReloc{int(read_u32(rel_bytes, ro)), int(read_u32(rel_bytes,
				ro + 4)), int(read_u16(rel_bytes, ro + 8))}
		}
	}
	// String table: length-prefixed at its end.
	str_len := int(read_u32(raw, symptr + v.nsym * 18))
	strtab := raw[symptr + v.nsym * 18..symptr + v.nsym * 18 + str_len]
	mut at := symptr
	// nsym counts symbol records including aux records, so aux entries are
	// skipped in the record count as well as in the offset.
	mut k := 0
	for k < v.nsym {
		mut nm := ''
		mut is_str := read_u32(raw, at) == 0
		if is_str {
			off := int(read_u32(raw, at + 4))
			mut j := off
			for strtab[j] != 0 {
				nm += strtab[j].ascii_str()
				j++
			}
		} else {
			for j in 0 .. 8 {
				if raw[at + j] == 0 {
					break
				}
				nm += raw[at + j].ascii_str()
			}
		}
		class := raw[at + 16]
		has_aux := raw[at + 17] == 1
		aux0 := if has_aux { int(read_u32(raw, at + 18)) } else { 0 }
		aux4 := if has_aux { int(read_u16(raw, at + 18 + 4)) } else { 0 }
		aux6 := if has_aux { int(read_u16(raw, at + 18 + 12)) } else { 0 }
		v.syms << CoffSym{nm, int(read_u32(raw, at + 8)), int(read_u16(raw, at + 12)), class, has_aux, k, aux0, aux4, aux6}
		at += 18
		k++
		if has_aux {
			at += 18
			k++
		}
	}
	return v
}

fn build_object(asm_text string, name string) CoffView {
	os.mkdir_all(scratch) or { panic(err.msg()) }
	path := scratch + '/' + name
	out := masm.assemble(asm_text) or { panic(err.msg()) }
	write_object(out, path) or { panic(err.msg()) }
	return view_object(path)
}

fn test_minimal_object_matches_gas_conventions() {
	v := build_object('  .file "vcc"\n  .text\n  .globl add\nadd:\n  ret\n  .data\n  .align 1\n.L..1:\n  .byte 97\n  .byte 0\n',
		'min.o')
	assert v.sections.map(it.name) == ['.text', '.data', '.bss']
	assert v.sections[0].chars == 0x60500020
	assert v.sections[1].chars == 0xc0500040
	assert v.sections[2].chars == 0xc0500080
	// No relocations: characteristics carry RELOCS_STRIPPED, like GAS.
	assert v.chars == 0x5
	// File + 3 section syms + add = 5 symbol records (4 with aux).
	names := v.syms.map(it.name)
	assert '.file' in names
	assert '.text' in names
	assert 'add' in names
	add := v.syms.filter(it.name == 'add')[0]
	assert add.section == 1 && add.class == 2 && !add.has_aux
}

fn test_external_relocation_object() {
	v := build_object('  .text\n  .globl main\nmain:\n  lea printf(%rip), %rax\n  ret\n',
		'ext.o')
	assert v.chars == 0x4
	assert v.sections[0].nrel == 1
	assert v.relocs.len == 1
	assert v.relocs[0].off == 3
	assert v.relocs[0].type_ == 4
	printf := v.syms.filter(it.name == 'printf')[0]
	assert printf.section == 0 && printf.class == 2
	// Records: file(0) text(2) data(4) bss(6) main(8) printf(9).
	assert printf.rec == 9
	assert v.relocs[0].sym == printf.rec
	text := v.syms.filter(it.name == '.text')[0]
	assert text.aux4 == 1
}

fn test_data_quad_and_section_symbol() {
	v := build_object('  .data\n  .align 1\n.L..1:\n  .byte 65\n  .byte 0\n  .quad .L..1+0\n',
		'data.o')
	assert v.sections[1].nrel == 1
	assert v.relocs.len == 1
	assert v.relocs[0].type_ == 1
	// Section-relative: the relocation names .data at record 4.
	data := v.syms.filter(it.name == '.data')[0]
	assert data.rec == 4
	assert v.relocs[0].sym == data.rec
	assert data.aux0 == 10
}

fn test_bss_carries_virtual_size() {
	// A .bss section has no raw bytes, so VirtualSize is its only size.
	// Writing 0 (as for .text/.data) makes the loader allocate nothing and
	// zero-init globals read garbage — measured via a BF tape that came up
	// non-zero.
	v := build_object('  .bss\n  .align 16\nbig:\n  .zero 30000\n  .text\n  .globl main\nmain:\n  ret\n',
		'bss.o')
	assert v.sections[2].name == '.bss'
	assert v.sections[2].vsize == 30000
	assert v.sections[2].rawsz == 0
	assert v.sections[0].vsize == 0
}

fn test_long_names_use_string_table() {
	v := build_object('  .text\n  .globl a_very_long_function_name\n' +
		'a_very_long_function_name:\n  ret\n', 'long.o')
	got := v.syms.filter(it.name == 'a_very_long_function_name')
	assert got.len == 1
	assert got[0].section == 1
}
