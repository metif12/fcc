module masm

// Machine-code assembler for fcc's text assembly (phase 3).
//
// `Assemble.text` is what `AsGen` prints: AT&T lines with `.globl`, `.text`,
// `.data`, `.bss`, `.align`, `.zero`, `.byte`, `.quad`, `name:` labels and
// instructions. The output is section bytes plus relocations, which `src/coff`
// writes as a COFF object. No external assembler is involved.
//
// The assembly dialect is exactly what `src/backend` emits, not all of GAS:
// anything outside it (SIB/indexed memory, `%fs:`, an unknown mnemonic) is a
// hard error naming the line, never a guessed encoding.

pub enum RelocKind {
	rel32
	addr64
	addr32
}

pub struct Reloc {
pub mut:
	// offset is the section-relative offset of the field to relocate.
	offset int
	// symbol names the relocation target: a section name (`.text`, `.data`)
	// for section-relative references, or a symbol for undefined ones.
	symbol string
	kind   RelocKind
}

pub struct SymbolDef {
pub mut:
	name string
	// section is 1 (.text), 2 (.data) or 3 (.bss). 0 means undefined,
	// which is an error for a definition and a relocation for a reference.
	section int
	offset  int
	// is_global is set by `.globl`. A global definition is EXTERNAL in COFF,
	// a non-global one STATIC.
	is_global bool
}

pub struct AsmOut {
pub mut:
	text        []u8
	text_relocs []Reloc
	data        []u8
	data_relocs []Reloc
	bss_size    int
	symbols     []SymbolDef
	file_name   string
	// text_len and data_len are the unpadded section lengths, for the
	// section symbols' aux records (scnlen). text/data above are padded
	// to 16 bytes, which is what SizeOfRawData carries.
	text_len int
	data_len int
}

// Fixup is one label reference inside emitted section bytes. Pass 1 records
// them with zeroed fields; pass 2 patches internal references and turns the
// rest into relocations.
struct Fixup {
	section int
	at      int
	label   string
	kind    RelocKind
	size    int
	// addend is written into the field for symbol references (e.g. the `+N`
	// of `.quad sym+N`); section-relative references add the label's section
	// offset to it in pass 2.
	addend int
	// numeric_dir resolves `1b`/`2f`: -1 backward, +1 forward, 0 not numeric.
	numeric_dir int
}

struct NumericDef {
	section int
	offset  int
}

const section_text = 1
const section_data = 2
const section_bss = 3

enum StmtKind {
	label
	dir
	instr
}

// Stmt is one parsed assembly statement. Parsing records everything first so
// jump shortening (short vs near encodings change every later offset) can
// iterate to a fixpoint before a single byte is emitted.
struct Stmt {
pub mut:
	kind StmtKind
	// section is the section this statement belongs to, tracked at parse.
	section int
	// label name for .label statements.
	label string
	// dir and dir_arg for directives (.text/.data/.bss/.align/.zero/.byte/.quad).
	dir     string
	dir_arg string
	// instruction fields.
	mn   string
	ops  []Operand
	frag string
	// short_jump is set by the sizing pass for same-section jumps that fit
	// in the 2-byte form, exactly the relaxation GAS performs.
	short_jump bool
	// offset is the section-relative offset assigned by the sizing pass.
	offset int
}

// assemble turns fcc's assembly text into section bytes and relocations.
pub fn assemble(text string) !AsmOut {
	mut a := Assembler{}
	a.parse(text)!
	a.sizes()!
	a.emit_all()!
	a.resolve()!
	return a.finish()
}

struct Assembler {
mut:
	text        []u8
	data        []u8
	bss_size    int
	cur         int = 1
	stmts       []Stmt
	symbols     []SymbolDef
	sym_idx     map[string]int
	globals     map[string]bool
	file_name   string
	fixups      []Fixup
	numerics    map[string][]NumericDef
	text_relocs []Reloc
	data_relocs []Reloc
	// label_pos is the sizing snapshot: label name -> section and offset.
	label_pos map[string]LabelPos
	// num_pos is the sizing snapshot for numeric labels.
	num_pos map[string][]NumericDef
}

struct LabelPos {
	section int
	offset  int
}

fn (mut a Assembler) parse(text string) ! {
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('//') {
			continue
		}
		if line.starts_with('#') {
			continue
		}
		// One source line can hold several `;`-separated statements (the
		// uint64-to-double conversion in gen.v is a single `g.line`).
		for frag in split_statements(line) {
			f := frag.trim_space()
			if f == '' {
				continue
			}
			a.parse_statement(f)!
		}
	}
}

// split_statements splits on `;`, which is GAS's statement separator. Quoted
// symbol names cannot contain `;` (C identifiers), so no quote tracking is
// needed; that restriction is asserted by the operand parser, not assumed.
fn split_statements(line string) []string {
	return line.split(';')
}

fn (mut a Assembler) parse_statement(frag string) ! {
	if frag.starts_with('.') && !frag.ends_with(':') {
		a.parse_directive(frag)!
		return
	}
	if frag.ends_with(':') {
		a.push_label(frag[..frag.len - 1].trim_space())!
		return
	}
	// GAS allows `label: instruction` on one line; the uint64-to-double
	// sequence in gen.v uses it (`...jmp 2f; 1: mov %rax,%rcx; ...`).
	if idx := frag.index(':') {
		head := frag[..idx].trim_space()
		rest := frag[idx + 1..].trim_space()
		if rest != '' && is_label_head(head) {
			a.push_label(unquote_sym(head))!
			a.parse_statement(rest)!
			return
		}
	}
	a.parse_instruction(frag)!
}

fn (mut a Assembler) push_label(name string) ! {
	ln := unquote_sym(name.trim_space())
	if ln == '' {
		return error('empty label')
	}
	a.stmts << Stmt{
		kind:    .label
		section: a.cur
		label:   ln
	}
}

fn (mut a Assembler) parse_directive(frag string) ! {
	mut parts := frag.split(' ')
	mn := parts[0]
	rest := if parts.len > 1 { frag[mn.len..].trim_space() } else { '' }
	match mn {
		'.file' {
			a.file_name = unquote_string(rest)!
		}
		'.globl' {
			name := unquote_sym(rest)
			if name == '' {
				return error('.globl without a name')
			}
			a.globals[name] = true
		}
		'.text' {
			a.cur = section_text
			a.stmts << Stmt{ kind: .dir, section: a.cur, dir: mn }
		}
		'.data' {
			a.cur = section_data
			a.stmts << Stmt{ kind: .dir, section: a.cur, dir: mn }
		}
		'.bss' {
			a.cur = section_bss
			a.stmts << Stmt{ kind: .dir, section: a.cur, dir: mn }
		}
		'.align', '.zero', '.byte', '.quad' {
			a.stmts << Stmt{ kind: .dir, section: a.cur, dir: mn, dir_arg: rest }
		}
		else {
			return error('unsupported directive "${mn}"')
		}
	}
}

fn (mut a Assembler) parse_instruction(frag string) ! {
	mut mn := frag
	mut rest := ''
	if idx := frag.index(' ') {
		mn = frag[..idx]
		rest = frag[idx + 1..].trim_space()
	} else if idx := frag.index('\t') {
		mn = frag[..idx]
		rest = frag[idx + 1..].trim_space()
	}
	mut ops := []Operand{}
	if rest != '' {
		for part in rest.split(',') {
			ops << parse_operand(part.trim_space())!
		}
	}
	a.stmts << Stmt{
		kind:       .instr
		section:    a.cur
		mn:         mn.to_lower()
		ops:        ops
		frag:       frag
		// Jumps start short and widen on overflow (the relaxation GAS
		// performs). Starting near instead gets stuck: a jump that only
		// fits once it is short never shortens.
		short_jump: is_jump(mn.to_lower())
	}
}

// sizes assigns every statement its section-relative offset, widening
// same-section jumps to the 6-byte near form when the displacement does not
// fit, exactly the relaxation GAS performs. Flags only move short->near, so
// the fixpoint terminates (each jump widens at most once).
fn (mut a Assembler) sizes() ! {
	for _ in 0 .. 100 {
		if a.size_pass()! {
			return
		}
	}
	return error('jump relaxation did not converge')
}

// size_pass assigns offsets with the current short_jump flags and recomputes
// them from the snapshot. It returns true when nothing changed.
fn (mut a Assembler) size_pass() !bool {
	mut lens := map[string]int{}
	lens['1'] = a.text.len
	lens['2'] = a.data.len
	lens['3'] = a.bss_size
	mut label_pos := map[string]LabelPos{}
	mut num_pos := map[string][]NumericDef{}
	mut changed := false
	// First pass: assign offsets and record label positions.
	for mut st in a.stmts {
		sec := st.section
		off := lens[sec.str()]
		st.offset = off
		match st.kind {
			.label {
				if is_numeric_label(st.label) {
					key := '${sec}:${st.label}'
					if key in num_pos {
						num_pos[key] << NumericDef{sec, off}
					} else {
						num_pos[key] = [NumericDef{sec, off}]
					}
				} else {
					label_pos[st.label] = LabelPos{sec, off}
				}
			}
			.dir {
				lens[sec.str()] = off + a.dir_size(st, off)!
			}
			.instr {
				bytes, _ := encode(st.mn, st.ops, st.frag, st.short_jump)!
				lens[sec.str()] = off + bytes.len
			}
		}
	}
	a.label_pos = label_pos.clone()
	a.num_pos = num_pos.clone()
	// Second pass: recompute short_jump flags from the snapshot.
	for mut st in a.stmts {
		if st.kind != .instr || !is_jump(st.mn) {
			continue
		}
		if st.ops.len != 1 {
			continue
		}
		short, known := a.jump_fits_short(st)
		if !known {
			// Undefined or cross-section target: near, permanently.
			if st.short_jump {
				st.short_jump = false
				changed = true
			}
			continue
		}
		if short != st.short_jump {
			st.short_jump = short
			changed = true
		}
	}
	return !changed
}

fn is_jump(mn string) bool {
	return mn in ['jmp', 'je', 'jne', 'jl', 'jle', 'jg', 'jge', 'jb', 'jbe', 'ja', 'jae', 'js',
		'jns', 'jp', 'jnp', 'jo', 'jno']
}

// jump_fits_short reports whether a jump's displacement fits the 2-byte form
// and whether the target is known at all (same section, snapshot offsets).
fn (mut a Assembler) jump_fits_short(st Stmt) (bool, bool) {
	op := st.ops[0]
	target := if op.kind == .sym {
		op.sym
	} else if op.kind == .numref {
		op.sym
	} else {
		return false, false
	}
	if op.kind == .sym {
		pos := a.label_pos[target] or { return false, false }
		if pos.section != st.section {
			return false, false
		}
		disp := pos.offset - (st.offset + 2)
		return disp >= -128 && disp <= 127, true
	}
	// Numeric local label: nearest definition in the snapshot.
	key := '${st.section}:${target}'
	defs := a.num_pos[key] or { return false, false }
	mut want := -1
	if op.numdir < 0 {
		for d in defs {
			if d.offset <= st.offset && d.offset > want {
				want = d.offset
			}
		}
	} else {
		for d in defs {
			if d.offset > st.offset && (want < 0 || d.offset < want) {
				want = d.offset
			}
		}
	}
	if want < 0 {
		return false, false
	}
	disp := want - (st.offset + 2)
	return disp >= -128 && disp <= 127, true
}

fn (mut a Assembler) dir_size(st Stmt, off int) !int {
	match st.dir {
		'.text', '.data', '.bss' { return 0 }
		'.align' {
			n := st.dir_arg.int()
			if n <= 0 || (n & (n - 1)) != 0 {
				return error('unsupported .align ${st.dir_arg}: must be a power of two')
			}
			mut pad := 0
			for (off + pad) % n != 0 {
				pad++
			}
			return pad
		}
		'.zero' {
			n := st.dir_arg.int()
			if n < 0 {
				return error('unsupported .zero ${st.dir_arg}')
			}
			return n
		}
		'.byte' { return 1 }
		'.quad' { return 8 }
		else { return error('unsupported directive "${st.dir}"') }
	}
}

// is_label_head reports a bare label definition prefix: an identifier, a
// quoted name, or a numeric local label. Operands never contain a bare colon
// (no segment overrides in this dialect), so this cannot misfire.
fn is_label_head(s string) bool {
	if s == '' {
		return false
	}
	if is_numeric_label(s) {
		return true
	}
	if s.starts_with('"') && s.ends_with('"') && s.len >= 2 {
		return true
	}
	for i, c in s {
		if c.is_letter() || c == `_` || c == `.` || c == `$` || (c.is_digit() && i > 0) {
			continue
		}
		return false
	}
	return true
}

// emit_all walks the sized statements and produces bytes plus fixups.
// Label offsets come from the sizing pass, so emission is a single pass.
fn (mut a Assembler) emit_all() ! {
	for st in a.stmts {
		a.cur = st.section
		match st.kind {
			.label {
				a.define_label_at(st.label, st.offset)!
			}
			.dir {
				a.emit_dir(st)!
			}
			.instr {
				a.emit_instruction(st)!
			}
		}
	}
}

fn (mut a Assembler) section_len() int {
	return match a.cur {
		section_text { a.text.len }
		section_data { a.data.len }
		section_bss { a.bss_size }
		else { 0 }
	}
}

fn (mut a Assembler) emit_byte(b u8) {
	match a.cur {
		section_text { a.text << b }
		section_data { a.data << b }
		section_bss { a.bss_size++ }
		else {}
	}
}

fn (mut a Assembler) emit_bytes(bs []u8) {
	for b in bs {
		a.emit_byte(b)
	}
}

fn (mut a Assembler) define_label_at(name string, at int) ! {
	if name == '' {
		return error('empty label')
	}
	if is_numeric_label(name) {
		key := '${a.cur}:${name}'
		if key in a.numerics {
			a.numerics[key] << NumericDef{a.cur, at}
		} else {
			a.numerics[key] = [NumericDef{a.cur, at}]
		}
		return
	}
	ln := unquote_sym(name)
	if ln in a.sym_idx {
		return error('duplicate label "${ln}"')
	}
	a.sym_idx[ln] = a.symbols.len
	a.symbols << SymbolDef{
		name:      ln
		section:   a.cur
		offset:    at
		is_global: ln in a.globals
	}
}

fn (mut a Assembler) emit_dir(st Stmt) ! {
	match st.dir {
		'.text', '.data', '.bss' {}
		'.align' {
			n := st.dir_arg.int()
			pad := if a.cur == section_text { u8(0x90) } else { u8(0) }
			for a.section_len() % n != 0 {
				a.emit_byte(pad)
			}
		}
		'.zero' {
			for _ in 0 .. st.dir_arg.int() {
				a.emit_byte(0)
			}
		}
		'.byte' {
			v := parse_number(st.dir_arg)!
			if v < 0 || v > 255 {
				return error('unsupported .byte ${st.dir_arg}: out of range')
			}
			a.emit_byte(u8(v))
		}
		'.quad' {
			sym, addend := split_quad_operand(st.dir_arg)!
			at := a.section_len()
			for _ in 0 .. 8 {
				a.emit_byte(0)
			}
			a.fixups << Fixup{
				section: a.cur
				at:      at
				label:   sym
				kind:    .addr64
				size:    8
				addend:  addend
			}
		}
		else {
			return error('unsupported directive "${st.dir}"')
		}
	}
}

fn is_numeric_label(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// unquote_sym strips the double quotes GAS needs around `$` names in operand
// position. Label definitions and `.globl` take the bare name.
fn unquote_sym(s string) string {
	t := s.trim_space()
	if t.len >= 2 && t.starts_with('"') && t.ends_with('"') {
		return t[1..t.len - 1]
	}
	return t
}

fn unquote_string(s string) !string {
	t := s.trim_space()
	if t.len >= 2 && t.starts_with('"') && t.ends_with('"') {
		return t[1..t.len - 1]
	}
	return error('expected a quoted string, found "${s}"')
}

fn split_quad_operand(s string) !(string, int) {
	t := s.trim_space()
	if t == '' {
		return error('empty .quad operand')
	}
	// A bare number is absolute data, encoded by the caller path instead;
	// here it is an error to keep `.quad` pointer-only and explicit.
	for i := 1; i < t.len; i++ {
		if t[i] == `+` {
			base := t[..i].trim_space()
			add := t[i + 1..].trim_space().i64()
			return unquote_sym(base), int(add)
		}
		if t[i] == `-` && t[i - 1] != `(` {
			base := t[..i].trim_space()
			sub := t[i + 1..].trim_space().i64()
			return unquote_sym(base), int(-sub)
		}
	}
	return unquote_sym(t), 0
}

fn (mut a Assembler) emit_instruction(st Stmt) ! {
	bytes, fixes := encode(st.mn, st.ops, st.frag, st.short_jump)!
	base := a.section_len()
	a.emit_bytes(bytes)
	for fx in fixes {
		a.fixups << Fixup{
			section:     a.cur
			at:          base + fx.at
			label:       fx.label
			kind:        fx.kind
			size:        fx.size
			addend:      fx.addend
			numeric_dir: fx.numeric_dir
		}
	}
}

// resolve patches internal references and turns the rest into relocations.
fn (mut a Assembler) resolve() ! {
	for fx in a.fixups {
		if fx.numeric_dir != 0 {
			target := a.resolve_numeric(fx)!
			a.patch(fx, target)!
			continue
		}
		idx := a.sym_idx[fx.label] or {
			// Undefined: relocate against the symbol itself. A 1-byte field
			// cannot carry a relocation (the sizing pass forces near jumps
			// for unknown targets), so this is an internal inconsistency.
			if fx.size == 1 {
				return error('short jump to undefined label "${fx.label}"')
			}
			a.add_reloc(fx, fx.label)
			continue
		}
		s := a.symbols[idx]
		if s.section == fx.section && fx.kind == .rel32 {
			// Same-section RIP-relative reference: resolved internally,
			// exactly what GAS does for `lea add(%rip)` in the s1 probe.
			// Absolute references (.quad) always relocate: the linked
			// address is not known until link time.
			a.patch(fx, s.offset)!
			continue
		}
		if s.section != 0 {
			// Defined elsewhere in this object (or absolute in the same
			// section): relocate section-relative with the label's section
			// offset plus the explicit addend (`.quad sym+N`) folded in.
			a.add_reloc(fx, section_name(s.section))
			a.add_to_field(fx, s.offset + fx.addend)
			continue
		}
		// Defined but sectionless (should not happen): symbol relocation.
		a.add_reloc(fx, fx.label)
	}
}

fn (mut a Assembler) resolve_numeric(fx Fixup) !int {
	key := '${fx.section}:${fx.label}'
	defs := a.numerics[key] or { return error('undefined local label "${fx.label}"') }
	if fx.numeric_dir < 0 {
		mut best := -1
		for d in defs {
			if d.offset <= fx.at && d.offset > best {
				best = d.offset
			}
		}
		if best < 0 {
			return error('local label "${fx.label}b" has no backward definition')
		}
		return best
	}
	mut best := -1
	for d in defs {
		if d.offset > fx.at && (best < 0 || d.offset < best) {
			best = d.offset
		}
	}
	if best < 0 {
		return error('local label "${fx.label}f" has no forward definition')
	}
	return best
}

// patch writes target-(field_end) into the fixup field (REL32 semantics for
// an internal reference).
fn (mut a Assembler) patch(fx Fixup, target int) ! {
	disp := target - (fx.at + fx.size)
	a.write_field(fx, i64(disp) + i64(fx.addend))
}

fn (mut a Assembler) add_to_field(fx Fixup, v int) {
	cur := a.read_field(fx)
	a.write_field(fx, cur + i64(v))
}

fn (mut a Assembler) read_field(fx Fixup) i64 {
	mut v := i64(0)
	for i in 0 .. fx.size {
		v |= i64(a.get_byte(fx.section, fx.at + i)) << (u64(i) * 8)
	}
	return v
}

fn (mut a Assembler) write_field(fx Fixup, v i64) {
	for i in 0 .. fx.size {
		a.set_byte(fx.section, fx.at + i, u8((v >> (u64(i) * 8)) & 0xff))
	}
}

fn (mut a Assembler) get_byte(section int, at int) u8 {
	return match section {
		section_text { a.text[at] }
		section_data { a.data[at] }
		else { 0 }
	}
}

fn (mut a Assembler) set_byte(section int, at int, b u8) {
	match section {
		section_text { a.text[at] = b }
		section_data { a.data[at] = b }
		else {}
	}
}

fn (mut a Assembler) add_reloc(fx Fixup, symbol string) {
	r := Reloc{
		offset: fx.at
		symbol: symbol
		kind:   fx.kind
	}
	match fx.section {
		section_text { a.text_relocs << r }
		section_data { a.data_relocs << r }
		else {}
	}
}

fn section_name(section int) string {
	return match section {
		section_text { '.text' }
		section_data { '.data' }
		section_bss { '.bss' }
		else { '' }
	}
}

fn (mut a Assembler) finish() !AsmOut {
	// Record the unpadded lengths first: the section aux records carry
	// scnlen (actual size), while the raw data is padded to 16.
	text_len := a.text.len
	data_len := a.data.len
	// Pad raw sections to 16 bytes, matching GAS (s1: 9 content bytes of
	// .data become 16; the tail of .text is 0x90).
	for a.text.len % 16 != 0 {
		a.text << u8(0x90)
	}
	for a.data.len % 16 != 0 {
		a.data << u8(0)
	}
	mut out := AsmOut{
		text:        a.text.clone()
		text_relocs: a.text_relocs.clone()
		data:        a.data.clone()
		data_relocs: a.data_relocs.clone()
		bss_size:    a.bss_size
		file_name:   a.file_name
		text_len:    text_len
		data_len:    data_len
	}
	for s in a.symbols {
		if s.name.starts_with('.L') {
			// Section-local labels never reach the symbol table; references
			// to them went out as section-relative relocations.
			continue
		}
		out.symbols << SymbolDef{
			name:      s.name
			section:   s.section
			offset:    s.offset
			is_global: s.name in a.globals
		}
	}
	// Undefined symbols referenced by relocations enter the table as
	// undefined EXTERNALs, mirroring GAS (printf/vprintf in the v probe).
	mut seen := map[string]bool{}
	for s in out.symbols {
		seen[s.name] = true
	}
	for r in a.text_relocs {
		a.add_undef(mut out, mut seen, r.symbol)
	}
	for r in a.data_relocs {
		a.add_undef(mut out, mut seen, r.symbol)
	}
	return out
}

fn (mut a Assembler) add_undef(mut out AsmOut, mut seen map[string]bool, name string) {
	if name in seen {
		return
	}
	if name.starts_with('.') {
		// Section symbols are emitted by the COFF writer itself.
		seen[name] = true
		return
	}
	seen[name] = true
	out.symbols << SymbolDef{
		name:      name
		section:   0
		offset:    0
		is_global: true
	}
}

// parse_number reads a decimal or 0x-prefixed hex integer.
pub fn parse_number(s string) !i64 {
	t := s.trim_space()
	if t.starts_with('0x') || t.starts_with('0X') {
		return i64(t[2..].parse_uint(16, 64)!)
	}
	return t.i64()
}
