module vcc

import ast

// Rendering the parse result as text.
//
// This is phase 1's acceptance signal: `--dump-ast` completing over a corpus is what
// says the front end read every declaration. It is also the only way to see a layout
// decision without running a program, which is why it prints member offsets and
// bit positions rather than just type names.

// type_name spells a type the way it would be written in C.
//
// Declarator syntax puts the name inside the type, so a spelled type is assembled from
// the pieces the parser kept: the base, and then the suffixes in the order they nest.
pub fn type_name(ty &ast.Type) string {
	return spell(ty, '')
}

// spell returns the declaration of `ty` as it would read with `name` in it.
fn spell(ty &ast.Type, name string) string {
	match ty.kind {
		.basic { return basic_name(ty) }
		.pointer {
			// `int *p` rather than `int* p`, so a name never runs into the star.
			return spell(ty.base, '*' + name)
		}
		.array {
			return spell(ty.base, name + suffix_array(ty))
		}
		.vla { return spell(ty.base, name + '[*]') }
		.func {
			mut params := []string{}
			for p in ty.params {
				params << type_name(p)
			}
			if ty.params.len == 0 && ty.is_variadic {
				params = ['']
			} else if ty.is_variadic {
				params << '...'
			}
			return spell(ty.ret_type, name + '(' + params.join(', ') + ')')
		}
		.struct_, .union_, .enum_ {
			// A tagged type is spelled by its tag, which is a different thing from the
			// declarator's name: `struct S s;` has both, and `ty.name` is the `s`.
			// A tagless type has only its layout, so the kind alone is all it can say.
			if ty.tag != '' {
				return kind_name(ty) + ' ' + ty.tag
			}
			return if name != '' { name } else { kind_name(ty) }
		}
		else { return '?' }
	}
}

// basic_name spells a basic type, including its signedness.
fn basic_name(ty &ast.Type) string {
	mut name := match ty.basic {
		.void_ { 'void' }
		.bool_ { '_Bool' }
		.char_ { 'char' }
		.short_ { 'short' }
		.int_ { 'int' }
		.long_ { 'long' }
		.llong_ { 'long long' }
		.float_ { 'float' }
		.double_ { 'double' }
		.ldouble_ { 'long double' }
		.enum_ { 'enum' }
		else { 'int' }
	}
	if ty.is_unsigned && ty.basic !in [.bool_, .char_] {
		name = 'unsigned ' + name
	}
	return name
}

fn suffix_array(ty &ast.Type) string {
	if ty.array_len < 0 {
		return '[]'
	}
	return '[' + ty.array_len.str() + ']'
}

// kind_name spells a tagged type's keyword.
fn kind_name(ty &ast.Type) string {
	return match ty.kind {
		.struct_ { 'struct' }
		.union_ { 'union' }
		.enum_ { 'enum' }
		else { 'type' }
	}
}

// dump_types appends a readable rendering of every global declaration.
//
// The output is deliberately a report rather than a machine format: it is read by a
// person chasing down which declaration came out wrong, and the corpus sweep greps it
// for the phrase the parser emits when it meets something it cannot read.
pub fn (r ParseResult) dump() string {
	mut out := []string{}
	for obj in r.globals {
		// A generated name — a string literal, a compound literal, `__func__` — is an
		// implementation detail of the translation, and listing it would bury the
		// declarations a reader came for.
		if obj.name.starts_with('.L.') {
			continue
		}
		out << dump_obj(obj)
	}
	return out.join('\n') + '\n'
}

fn dump_obj(obj &ast.Obj) string {
	mut b := []string{}
	mut kind := 'variable'
	if obj.is_function {
		kind = 'function'
	}
	if obj.is_static {
		kind = 'static ' + kind
	}
	if obj.is_tls {
		kind = 'thread_local ' + kind
	}
	if obj.is_definition {
		kind += ' definition'
	} else {
		kind += ' declaration'
	}
	if obj.is_tentative {
		kind += ' tentative'
	}
	b << '${obj.line}: ${kind} ${type_name(obj.ty)}  // ${obj.name}'
	b << '  size=${obj.ty.size} align=${obj.ty.align} init_align=${obj.align}'

	if obj.is_function {
		b << dump_frame(obj)
	} else if obj.init_data.len > 0 {
		b << '  bytes=${hex_bytes(obj.init_data)}'
	}
	for rel in obj.rel {
		b << '  reloc at ${rel.offset}: ${rel.label}${if rel.addend < 0 { rel.addend.str() } else { '+' + rel.addend.str() }}'
	}
	if obj.ty.kind == .struct_ || obj.ty.kind == .union_ {
		b << dump_members(obj.ty)
	}
	return b.join('\n')
}

// dump_frame renders a function's parameters and locals.
//
// The locals are the interesting part for a front end under test: a local that appears
// here is one the body created, so a missing declaration shows up as a missing entry
// rather than as a wrong instruction later.
fn dump_frame(obj &ast.Obj) string {
	mut b := []string{}
	params := obj.params.len
	mut frames := []string{}
	for i, local in obj.locals {
		role := if i < params { 'param' } else { 'local' }
		// A compound assignment and a `++` each introduce an unnamed temporary to hold
		// the target's address. It is listed rather than hidden because its absence is
		// how a frame-size bug shows up, and `<tmp>` says which object it is without
		// pretending it has a name.
		name := if local.name == '' { '<tmp>' } else { local.name }
		frames << '  ${role} ${type_name(local.ty)} ${name}'
	}
	if frames.len == 0 {
		return '  {}'
	}
	b << '  frame:'
	b << frames.join('\n')
	// `__alloca_size__` and `__va_area__` are the parser's own locals and are already in
	// the list; a statement count is what says the body itself produced something.
	b << '  body: ${obj.body.len} top-level statements'
	return b.join('\n')
}

// dump_members renders a struct's or union's layout.
//
// The bitfield columns are the reason this table exists: `offset` is the start of the
// storage unit and `bit_offset` is where in it the field begins, and only seeing both
// makes a bitfield layout checkable by eye.
fn dump_members(ty &ast.Type) string {
	if ty.members.len == 0 {
		return '  {}'
	}
	mut b := []string{}
	mut name_width := 0
	for mem in ty.members {
		if mem.name.len > name_width {
			name_width = mem.name.len
		}
	}
	for mem in ty.members {
		label := if mem.name == '' { '<anonymous>' } else { mem.name }
		mut line := '  ' + pad_right(label, name_width) + '  offset=' +
			mem.offset.str() + ' size=' + mem.ty.size.str() +
			' align=' + mem.align.str()
		if mem.is_bitfield {
			if mem.bit_width == 0 {
				line += '  bitfield: none (padding only)'
			} else {
				line += '  bits ${mem.bit_offset}..${mem.bit_offset + mem.bit_width} of ${mem.ty.size * 8}'
			}
		}
		b << line
	}
	if ty.is_flexible {
		b << '  (last member is a flexible array)'
	}
	if ty.pack != 0 {
		b << '  packed to ${ty.pack}'
	}
	return b.join('\n')
}

// pad_right appends spaces so a column of names lines up.
fn pad_right(s string, width int) string {
	mut out := s
	for _ in s.len .. width {
		out += ' '
	}
	return out
}

// hex_bytes renders a byte image, four bytes to a group, so that a value written by
// hand in a test can be compared with what the parser produced.
fn hex_bytes(data []u8) string {
	mut parts := []string{}
	for i, b in data {
		if i > 0 && i % 8 == 0 {
			parts << ' '
		}
		parts << b.hex()
	}
	return parts.join('')
}