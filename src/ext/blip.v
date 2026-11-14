module ext

import os
import src.core
import src.fcc

// Language plugin: Blip.
//
// Blip is fcc's own tiny scripting language: a deliberately small,
// line-oriented language that compiles to C through the same pipeline as
// everything else. It exists as a second worked example beside Brainfuck and
// Bash, showing how a language with variables, arithmetic, control flow and
// functions plugs in without touching the front end.
//
// Grammar (one statement per line; indentation is cosmetic):
//   print <expr>              // prints an int followed by newline
//   let x = <expr>            // declares an int variable
//   x = <expr>                // assigns
//   if <expr> { ... } else { ... }   (braces on their own lines)
//   while <expr> { ... }
//   for x in 1 2 3 { ... }    // loop over a list of int literals/vars
//   fn name(a, b) { ... }     // int function, implicit return 0
//   return <expr>
//
// Expressions: integers, variables, + - * / %, comparisons, ( ).
//
// Disable without touching code:
//   [plugin."example-blip-input"]
//   enabled = false

pub struct BlipInput {
pub:
	plugin_name string = 'example-blip-input'
}

pub fn (p BlipInput) name() string {
	return p.plugin_name
}

pub fn (p BlipInput) extensions() []string {
	return ['.blip', '.bl']
}

pub fn (p BlipInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.blip') || l.ends_with('.bl')
}

pub fn (p BlipInput) load(path string, mut ctx core.PipelineContext) ! {
	src := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	generated := transpile_blip(src, path) or {
		ctx.diagnostics << err.msg()
		ctx.failed = true
		return error('blip: ${err.msg()}')
	}
	mut pp := fcc.preprocessor(ctx.includes, ctx.sys_includes)
	for spec in ctx.defines {
		pp.define_from_option(spec)
	}
	for n in ctx.undefines {
		pp.undefine(n)
	}
	pp.define_builtins()
	pre := pp.run_text(generated, path)
	for e in pre.errors {
		ctx.diagnostics << '${path}: ${e}'
		ctx.failed = true
	}
	parsed := fcc.parse_tokens(pre.tokens, path, pp.packs)
	for e in parsed.errors {
		ctx.diagnostics << e
		ctx.failed = true
	}
	for w in parsed.warnings {
		ctx.diagnostics << w
	}
	if parsed.errors.len > 0 {
		return error('parse failed for ${path}')
	}
	ctx.globals << parsed.globals
}

pub fn register_blip() {
	core.register_input(BlipInput{})
}

// ---------- transpiler ----------

struct BlipTranspiler {
mut:
	lines  []string
	indent int
	vars   map[string]bool
}

fn new_blip_transpiler() BlipTranspiler {
	mut t := BlipTranspiler{}
	t.lines << '/* generated from blip by example-blip-input */'
	t.lines << '#include <stdio.h>'
	t.lines << '#include <stdlib.h>'
	return t
}

fn (mut t BlipTranspiler) emit(s string) {
	t.lines << '  '.repeat(t.indent) + s
}

fn (mut t BlipTranspiler) transpile(src string, origin string) {
	raw_lines := src.split('\n')
	mut start := 0
	if raw_lines.len > 0 && raw_lines[0].starts_with('#!') {
		start = 1
	}
	mut body := []string{}
	for i := start; i < raw_lines.len; i++ {
		body << raw_lines[i]
	}
	mut main_lines := []string{}
	mut i := 0
	for i < body.len {
		line := body[i].trim_space()
		if line == '' || line.starts_with('#') {
			i++
			continue
		}
		if line.starts_with('fn ') {
			name := line.all_after('fn ').all_before('(').trim_space()
			mut j := i
			for j < body.len && !body[j].contains('{') {
				j++
			}
			mut depth := 0
			mut func_body := []string{}
			if j < body.len {
				rem := body[j].all_after('{').trim_space()
				if rem != '' && rem != '}' {
					func_body << rem
				}
				depth = 1
				j++
			}
			for j < body.len && depth > 0 {
				l := body[j].trim_space()
				if l == '}' {
					depth--
					if depth == 0 {
						j++
						break
					}
				} else {
					if l.contains('{') { depth++ }
					if l.contains('}') { depth-- }
					if depth > 0 {
						func_body << body[j]
					}
				}
				j++
			}
			t.emit_func(name, line, func_body)
			i = j
			continue
		}
		main_lines << body[i]
		i++
	}
	t.lines << 'int main(void) {'
	t.indent = 1
	t.transpile_block(main_lines, 0, main_lines.len)
	t.indent = 0
	t.lines << '	return 0;'
	t.lines << '}'
}

fn is_blip_func_def(line string) bool {
	if !line.contains('(') || !line.contains(')') { return false }
	idx_paren := line.index(')') or { return false }
	after := line[idx_paren + 1..].trim_space()
	if after == '' || after == '{' || after.starts_with('{') {
		name := line.all_after('fn ').all_before('(').trim_space()
		if name != '' && !name.contains(' ') && !name.contains(';') {
			return true
		}
	}
	return false
}

fn (mut t BlipTranspiler) emit_func(name string, sig string, body []string) {
	mut params := sig.all_after('(').all_before(')').trim_space()
	mut param_list := []string{}
	if params != '' {
		for p in params.split(',') {
			pn := p.trim_space()
			if pn == '' { continue }
			param_list << 'int ' + pn
			if pn !in t.vars {
				t.vars[pn] = true
			}
		}
	}
	t.lines << ''
	t.lines << 'int ' + name + '(' + param_list.join(', ') + ') {'
	t.indent = 1
	t.transpile_block(body, 0, body.len)
	t.indent = 0
	t.lines << '}'
}

fn (mut t BlipTranspiler) transpile_block(lines []string, start int, end int) {
	mut i := start
	for i < end {
		line := lines[i].trim_space()
		if line == '' || line.starts_with('#') {
			i++
			continue
		}
		if line.starts_with('if ') {
			cond := blip_cond(line.all_after('if ').replace('{', '').trim_space())
			t.emit('if (' + cond + ') {')
			t.indent++
			mut j := i + 1
			mut depth := 1
			mut ifblock := []string{}
			mut elseblock := []string{}
			mut in_else := false
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == '}' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('if ') { depth++ }
				if depth == 1 && (l == 'else' || l.starts_with('else ') || l == 'else;' || l.contains(' else ') || l.contains(' else{')) {
					in_else = true
					t.indent--
					t.emit('} else {')
					t.indent++
					j++
					continue
				}
				if in_else {
					elseblock << lines[j]
				} else {
					ifblock << lines[j]
				}
				j++
			}
			t.transpile_block(ifblock, 0, ifblock.len)
			if elseblock.len > 0 {
				t.transpile_block(elseblock, 0, elseblock.len)
			}
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if line.starts_with('while ') {
			cond := blip_cond(line.all_after('while ').replace('{', '').trim_space())
			t.emit('while (' + cond + ') {')
			t.indent++
			mut j := i + 1
			mut depth := 1
			mut sub := []string{}
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == '}' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('while ') || l.starts_with('if ') { depth++ }
				sub << lines[j]
				j++
			}
			t.transpile_block(sub, 0, sub.len)
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if line.starts_with('for ') {
			varname := line.all_after('for ').all_before(' in ').trim_space()
			after_in := line.all_after(' in ').replace('; do', '').replace('do', '').replace('{', '').trim_space()
			words := after_in.split(' ')
			if varname !in t.vars {
				t.emit('int ' + varname + ' = 0;')
				t.vars[varname] = true
			}
			mut vals := []string{}
			for w in words {
				if w == '' { continue }
				vals << blip_expr(w)
			}
			if vals.len == 0 { vals << '0' }
			t.emit('for (int _bi = 0; _bi < ' + vals.len.str() + '; _bi++) {')
			t.indent++
			t.emit('static const int _bv[] = { ' + vals.join(', ') + ' };')
			t.emit(varname + ' = _bv[_bi];')
			mut j := i + 1
			mut depth := 1
			mut sub := []string{}
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == '}' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('for ') || l.starts_with('while ') || l.starts_with('if ') {
					depth++
				}
				sub << lines[j]
				j++
			}
			t.transpile_block(sub, 0, sub.len)
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if line.starts_with('print ') || line == 'print' {
			expr := line.all_after('print').trim_space()
			t.emit('printf("%d\\n", ' + blip_expr(expr) + ');')
			i++
			continue
		}
		if line.starts_with('let ') {
			rest := line.all_after('let ').trim_space()
			if rest.contains('=') {
				name := rest.all_before('=').trim_space()
				val := rest.all_after('=').trim_space()
				if name !in t.vars {
					t.emit('int ' + name + ' = ' + blip_expr(val) + ';')
					t.vars[name] = true
				} else {
					t.emit(name + ' = ' + blip_expr(val) + ';')
				}
			}
			i++
			continue
		}
		if line.starts_with('return ') || line == 'return' {
			expr := line.all_after('return').trim_space()
			if expr == '' {
				t.emit('return 0;')
			} else {
				t.emit('return ' + blip_expr(expr) + ';')
			}
			i++
			continue
		}
		if line.contains('=') && !line.starts_with('if') && !line.starts_with('while') && !line.starts_with('fn') && !line.starts_with('for') {
			name := line.all_before('=').trim_space()
			val := line.all_after('=').trim_space()
			if name != '' && is_blip_ident(name) {
				if name !in t.vars {
					t.emit('int ' + name + ' = ' + blip_expr(val) + ';')
					t.vars[name] = true
				} else {
					t.emit(name + ' = ' + blip_expr(val) + ';')
				}
				i++
				continue
			}
		}
		t.emit(blip_expr(line) + ';')
		i++
	}
}

fn blip_cond(s string) string {
	r := blip_expr(s)
	if r.starts_with('(') && r.ends_with(')') && blip_paren_balanced(r[1..r.len - 1]) {
		return r[1..r.len - 1]
	}
	return r
}

fn blip_expr(s string) string {
	return blip_parse_expr(s.trim_space())
}

fn blip_parse_expr(s string) string {
	mut e := s
	for e.starts_with('(') && e.ends_with(')') {
		if blip_paren_balanced(e[1..e.len - 1]) {
			e = e[1..e.len - 1].trim_space()
		} else {
			break
		}
	}
	mut depth := 0
	mut pos := -1
	mut op := ''
	for idx, c in e {
		if c == 40 { depth++ }
		if c == 41 { depth-- }
		if depth != 0 { continue }
		if c == 43 || c == 45 {
			pos = idx
			op = c.ascii_str()
		}
	}
	if pos >= 0 && op != '' {
		left := blip_parse_expr(e[..pos].trim_space())
		right := blip_parse_expr(e[pos + 1..].trim_space())
		return '(' + left + ' ' + op + ' ' + right + ')'
	}
	depth = 0
	pos = -1
	op = ''
	for idx, c in e {
		if c == 40 { depth++ }
		if c == 41 { depth-- }
		if depth != 0 { continue }
		if c == 42 || c == 47 || c == 37 {
			pos = idx
			op = c.ascii_str()
		}
	}
	if pos >= 0 && op != '' {
		left := blip_parse_expr(e[..pos].trim_space())
		right := blip_parse_expr(e[pos + 1..].trim_space())
		return '(' + left + ' ' + op + ' ' + right + ')'
	}
	for _, cop in ['==', '!=', '<=', '>=', '<', '>'] {
		mut idx2 := -1
		depth = 0
		for k := 0; k + cop.len <= e.len; k++ {
			if e[k] == 40 { depth++ }
			if e[k] == 41 { depth-- }
			if depth != 0 { continue }
			if e[k..k + cop.len] == cop {
				idx2 = k
			}
		}
		if idx2 >= 0 {
			left := blip_parse_expr(e[..idx2].trim_space())
			right := blip_parse_expr(e[idx2 + cop.len..].trim_space())
			return '(' + left + ' ' + cop + ' ' + right + ')'
		}
	}
	if e == '' { return '0' }
	mut allnum := true
	for c in e {
		if !c.is_digit() {
			allnum = false
			break
		}
	}
	if allnum && e != '' { return e }
	return e
}

fn blip_paren_balanced(s string) bool {
	mut d := 0
	for c in s {
		if c == 40 { d++ }
		if c == 41 {
			d--
			if d < 0 { return false }
		}
	}
	return d == 0
}

fn is_blip_ident(s string) bool {
	if s == '' { return false }
	if s[0].is_digit() { return false }
	for c in s {
		if !(c.is_letter() || c.is_digit() || c == 95) { return false }
	}
	return true
}

fn is_blip_int_literal(s string) bool {
	if s == '' { return false }
	mut i := 0
	if s.len > 0 && s[0] == 45 { i = 1 }
	if i >= s.len { return false }
	for j := i; j < s.len; j++ {
		if !s[j].is_digit() { return false }
	}
	return true
}

pub fn transpile_blip(src string, origin string) !string {
	mut t := new_blip_transpiler()
	t.transpile(src, origin)
	return t.lines.join('\n')
}
