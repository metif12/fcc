module ext

import os
import src.core
import src.fcc

// Language plugin: Bash, compiled to a native binary.
//
// Parses a subset of Bash into statements and emits real C, so the result is a
// compiled program rather than a script handed to a shell at runtime. It reuses
// the whole existing pipeline (frontend, both emitters, object writer) without
// touching any of it.
//
// Supported subset:
//   - comments (# to end of line)
//   - echo with word/quoted-string arguments and $var expansion
//   - variable assignment: name=value  (int or string)
//   - variable expansion: $name, ${name}
//   - if / then / elif / else / fi  with [ ] tests
//   - for name in word...; do ...; done
//   - while ...; do ...; done
//   - function definitions: name() { ... }
//
// Disable without touching code:
//   [plugin."example-bash-input"]
//   enabled = false

pub struct BashInput {
pub:
	plugin_name string = 'example-bash-input'
}

pub fn (p BashInput) name() string {
	return p.plugin_name
}

pub fn (p BashInput) extensions() []string {
	return ['.sh', '.bash']
}

pub fn (p BashInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.sh') || l.ends_with('.bash')
}

pub fn (p BashInput) load(path string, mut ctx core.PipelineContext) ! {
	src := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	generated := transpile_bash(src, path) or {
		ctx.diagnostics << err.msg()
		ctx.failed = true
		return error('bash: ${err.msg()}')
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

pub fn register_bash() {
	core.register_input(BashInput{})
}

// ---------- transpiler ----------

struct BashTranspiler {
mut:
	lines []string
	indent int
	vars  map[string]bool
}

fn new_bash_transpiler() BashTranspiler {
	mut t := BashTranspiler{}
	t.lines << '/* generated from bash by example-bash-input */'
	t.lines << '#include <stdio.h>'
	t.lines << '#include <stdlib.h>'
	t.lines << '#include <string.h>'
	return t
}

fn (mut t BashTranspiler) emit(s string) {
	t.lines << '  '.repeat(t.indent) + s
}

fn (mut t BashTranspiler) transpile(src string, origin string) {
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
		if is_func_def(line) {
			name := line.all_before('(').trim_space()
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
			t.emit_func(name, func_body)
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

fn is_func_def(line string) bool {
	if !line.contains('(') || !line.contains(')') { return false }
	idx_paren := line.index(')') or { return false }
	after := line[idx_paren+1..].trim_space()
	if after == '' || after == '{' || after.starts_with('{') {
		name := line.all_before('(').trim_space()
		if name != '' && !name.contains(' ') && !name.contains(';') {
			return true
		}
	}
	return false
}

fn (mut t BashTranspiler) emit_func(name string, body []string) {
	t.lines << ''
	t.lines << 'void ' + name + '(void) {'
	t.indent = 1
	t.transpile_block(body, 0, body.len)
	t.indent = 0
	t.lines << '}'
}

fn (mut t BashTranspiler) transpile_block(lines []string, start int, end int) {
	mut i := start
	for i < end {
		line := lines[i].trim_space()
		if line == '' || line.starts_with('#') {
			i++
			continue
		}
		if line.starts_with('if ') {
			cond_str := extract_if_cond(line)
			t.emit('if (' + cond_str + ') {')
			t.indent++
			mut j := i + 1
			mut depth := 1
			mut ifblock := []string{}
			mut elseblock := []string{}
			mut in_else := false
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == 'fi' || l.starts_with('fi ') || l == 'fi;' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('if ') { depth++ }
				if depth == 1 && (l == 'else' || l.starts_with('else ') || l == 'else;') {
					in_else = true
					j++
					continue
				}
				if depth == 1 && l.starts_with('elif ') {
					in_else = true
					t.indent--
					t.emit('} else if (' + extract_if_cond(l) + ') {')
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
				t.indent--
				t.emit('} else {')
				t.indent++
				t.transpile_block(elseblock, 0, elseblock.len)
			}
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if line.starts_with('for ') {
			varname := line.all_after('for ').all_before(' in ').trim_space()
			after_in := line.all_after(' in ').replace('; do', '').replace('do', '').trim_space()
			words := after_in.split(' ')
			if varname !in t.vars {
				t.emit('char *' + varname + ' = 0;')
				t.vars[varname] = true
			}
			mut elems := []string{}
			for w in words {
				if w == '' { continue }
				elems << '    "' + escape_c(strip_quotes(w)) + '"'
			}
			if elems.len == 0 { elems << '    ""' }
			t.emit('static const char *_ba_' + varname + '[] = {')
			t.emit(elems.join(',\n') + ',')
			t.emit('    NULL')
			t.emit('};')
			t.emit('for (int _bi = 0; _ba_' + varname + '[_bi] != NULL; _bi++) {')
			t.indent++
			t.emit(varname + ' = (char*)_ba_' + varname + '[_bi];')
			mut j := i + 1
			mut depth := 1
			mut sub := []string{}
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == 'done' || l.starts_with('done ') || l == 'done;' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('for ') || l.starts_with('while ') || l.starts_with('if ') { depth++ }
				sub << lines[j]
				j++
			}
			t.transpile_block(sub, 0, sub.len)
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if line.starts_with('while ') {
			cond_str := extract_if_cond(line)
			t.emit('while (' + cond_str + ') {')
			t.indent++
			mut j := i + 1
			mut depth := 1
			mut sub := []string{}
			for j < end && depth > 0 {
				l := lines[j].trim_space()
				if l == 'done' || l.starts_with('done ') || l == 'done;' {
					depth--
					if depth == 0 { break }
				}
				if l.starts_with('for ') || l.starts_with('while ') || l.starts_with('if ') { depth++ }
				sub << lines[j]
				j++
			}
			t.transpile_block(sub, 0, sub.len)
			t.indent--
			t.emit('}')
			i = j + 1
			continue
		}
		if is_assignment(line) {
			name := line.all_before('=').trim_space()
			val := line.all_after('=').trim_space()
			if name !in t.vars {
				if is_int_literal(val) || val == '' {
					t.emit('int ' + name + ' = ' + (if val == '' { '0' } else { val }) + ';')
				} else {
					t.emit('char *' + name + ' = "' + escape_c(strip_quotes(val)) + '";')
				}
				t.vars[name] = true
			} else {
				if is_int_literal(val) {
					t.emit(name + ' = ' + val + ';')
				} else {
					t.emit(name + ' = "' + escape_c(strip_quotes(val)) + '";')
				}
			}
			i++
			continue
		}
		if line.starts_with('echo ') || line == 'echo' {
			args := line.all_after('echo').trim_space()
			mut fmt := ''
			mut pargs := []string{}
			mut firstword := true
			for w in args.split(' ') {
				if w == '' { continue }
				if !firstword { fmt += ' ' }
				firstword = false
				bare := strip_quotes(w)
				if bare.starts_with('$') {
					name := bare.trim_left('$').trim_left('{').trim_right('}')
					fmt += '%s'
					pargs << name
				} else {
					fmt += escape_c(bare)
				}
			}
			fmt += '\\n'
			if pargs.len == 0 {
				t.emit('printf("' + fmt + '");')
			} else {
				t.emit('printf("' + fmt + '", ' + pargs.join(', ') + ');')
			}
			i++
			continue
		}
		t.emit(line + ';')
		i++
	}
}

fn extract_if_cond(line string) string {
	mut s := line
	for _, kw in ['if', 'elif', 'while'] {
		if s.starts_with(kw + ' ') {
			s = s[kw.len..].trim_space()
		}
	}
	s = s.replace('; then', '').replace('then', '').trim_space()
	if s.starts_with('[') {
		mut depth := 0
		mut end := -1
		for idx, c in s {
			if c == 91 { depth++ }
			if c == 93 { depth--; if depth == 0 { end = idx; break } }
		}
		if end >= 0 {
			inner := s[1..end].trim_space()
			s = translate_test(inner)
		}
	}
	return s
}

fn translate_test(inner string) string {
	parts := inner.split(' ')
	if parts.len >= 3 {
		lhs := bash_var_expr(parts[0])
		op := parts[1]
		rhs := bash_var_expr(parts[2])
		match op {
			'-eq' { return lhs + ' == ' + rhs }
			'-ne' { return lhs + ' != ' + rhs }
			'-lt' { return lhs + ' < ' + rhs }
			'-gt' { return lhs + ' > ' + rhs }
			'-le' { return lhs + ' <= ' + rhs }
			'-ge' { return lhs + ' >= ' + rhs }
			'=' { return 'strcmp(' + lhs + ', ' + rhs + ') == 0' }
			'!=' { return 'strcmp(' + lhs + ', ' + rhs + ') != 0' }
			else { return '0' }
		}
	}
	if parts.len == 2 {
		if parts[0] == '-z' {
			expr := bash_var_expr(parts[1])
			return '(' + expr + ' == 0 || ' + expr + '[0] == 0)'
		}
		if parts[0] == '-n' {
			expr := bash_var_expr(parts[1])
			return '(' + expr + ' != 0 && ' + expr + '[0] != 0)'
		}
	}
	return '0'
}

fn bash_var_expr(tok string) string {
	s := strip_quotes(tok)
	if s.starts_with('$') {
		name := s.trim_left('$').trim_left('{').trim_right('}')
		return name
	}
	if is_int_literal(s) { return s }
	return '"' + escape_c(s) + '"'
}

fn is_assignment(line string) bool {
	if line.contains(' ') { return false }
	if !line.contains('=') { return false }
	if line.contains('==') || line.contains('!=') { return false }
	name := line.all_before('=').trim_space()
	if name == '' { return false }
	for c in name {
		if !(c.is_letter() || c.is_digit() || c == 95) { return false }
	}
	if name[0].is_digit() { return false }
	return true
}

fn strip_quotes(s string) string {
	mut r := s
	if r.len >= 2 && (r[0] == 34 || r[0] == 39) && r[r.len-1] == r[0] {
		r = r[1..r.len-1]
	}
	return r
}

fn escape_c(s string) string {
	mut r := ''
	for c in s {
		match c {
			92 { r += '\\\\' }
			34 { r += '\\"' }
			10 { r += '\\n' }
			9 { r += '\\t' }
			13 { r += '\\r' }
			else { r += c.ascii_str() }
		}
	}
	return r
}

fn is_int_literal(s string) bool {
	if s == '' { return false }
	mut i := 0
	if s.len > 0 && s[0] == 45 { i = 1 }
	if i >= s.len { return false }
	for j := i; j < s.len; j++ {
		if !s[j].is_digit() { return false }
	}
	return true
}

pub fn transpile_bash(src string, origin string) !string {
	mut t := new_bash_transpiler()
	t.transpile(src, origin)
	return t.lines.join('\n')
}
