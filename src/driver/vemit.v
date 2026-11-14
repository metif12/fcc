module driver

import src.ast

// V emission: the `--to-v` / `--to-v-bindings` translators.
//
// This file holds the C-to-V backend that used to live in `driver.v`.
// It stays in `module driver` (rather than becoming its own module) because
// it is only reachable through the `emit_v` / `emit_v_bindings` CLI paths;
// promoting it would be a new public dependency for one flag. `driver.v`
// keeps option parsing, target selection and output dispatch.

fn vemit_bindings_unit(globals []&ast.Obj, typedefs map[string]&ast.Type) string {
	mut seen := map[string]bool{}
	mut structs := []string{}
	for name, t in typedefs {
		if t.kind == .struct_ || t.kind == .union_ {
			if name in seen {
				continue
			}
			seen[name] = true
			mut fields := []string{}
			for m in t.members {
				vemit_collect_type(m.ty, mut seen, mut structs)
				fields << '\t' + 'mut ' + v_safe_name(m.name) + ' ' + v_type(m.ty)
			}
			keyword := if t.kind == .union_ { 'struct /* union */' } else { 'struct' }
			cap := v_safe_name(name)
			cap_name := cap[0..1].to_upper() + cap[1..]
			structs << '${keyword} ${cap_name} {\n' + fields.join('\n') + '\n}'
		}
	}
	for obj in globals {
		vemit_collect_obj(obj, mut seen, mut structs)
	}

	mut lines := []string{}
	lines << 'module main'
	lines << ''
	for s in structs {
		lines << s
		lines << ''
	}

	// Globals as c_extern bindings.
	for obj in globals {
		if obj.is_function {
			continue
		}
		if !obj.is_definition && !obj.is_tentative {
			continue
		}
		lines << '@[c_extern]'
		lines << '__global C.${v_safe_name(obj.name)} ${v_type(obj.ty)}'
		lines << '@[weak]'
		lines << '__global ${v_safe_name(obj.name)} ${v_type(obj.ty)}'
		lines << ''
	}

	// Functions as extern declarations.
	for obj in globals {
		if !obj.is_function {
			continue
		}
		if obj.body.len == 0 && obj.params.len == 0 {
			continue
		}
		mut params := []string{}
		for param in obj.params {
			params << '${v_safe_name(param.name)} ${v_type(param.ty)}'
		}
		mut ret := 'void'
		if obj.ty != unsafe { nil } && obj.ty.kind == .func && obj.ty.ret_type != unsafe { nil } {
			ret = v_type(obj.ty.ret_type)
		}
		if obj.name == 'main' {
			ret = 'void'
		}
		mut decl := 'fn C.${v_safe_name(obj.name)}(${params.join(', ')}) ${ret}'
		if obj.ty != unsafe { nil } && obj.ty.kind == .func && obj.ty.is_variadic {
			if params.len > 0 {
				decl = 'fn C.${v_safe_name(obj.name)}(${params.join(', ')}, ...) ${ret}'
			} else {
				decl = 'fn C.${v_safe_name(obj.name)}(...) ${ret}'
			}
		}
		lines << decl
	}
	lines << ''

	return lines.join('\n')
}

fn vemit_unit(globals []&ast.Obj, typedefs map[string]&ast.Type) string {
	mut seen := map[string]bool{}
	mut structs := []string{}
	// Emit typedef'd structs/unions under their alias name first, so the rest
	// of the unit can refer to them by name.
	for name, t in typedefs {
		if t.kind == .struct_ || t.kind == .union_ {
			if name in seen {
				continue
			}
			seen[name] = true
			mut fields := []string{}
			for m in t.members {
				vemit_collect_type(m.ty, mut seen, mut structs)
				fields << '\t' + 'mut ' + v_safe_name(m.name) + ' ' + v_type(m.ty)
			}
			keyword := if t.kind == .union_ { 'union' } else { 'struct' }
			cap := v_safe_name(name)
			cap_name := cap[0..1].to_upper() + cap[1..]
			structs << '${keyword} ${cap_name} {\n' + fields.join('\n') + '\n}'
		}
	}
	for obj in globals {
		vemit_collect_obj(obj, mut seen, mut structs)
	}

	mut lines := []string{}
	lines << 'module main'
	lines << ''
	for s in structs {
		lines << s
		lines << ''
	}

	for obj in globals {
		if obj.is_function {
			continue
		}
		if !obj.is_definition {
			continue
		}
		if is_string_global(obj) {
			lines << 'const ${v_safe_name(obj.name)} = ${v_string_literal(obj.init_data)}'
			continue
		}
		lines << '__global ('
		lines << '\t${v_safe_name(obj.name)} ${v_type(obj.ty)}'
		lines << ')'
	}
	if globals.len > 0 {
		lines << ''
	}

	for obj in globals {
		if !obj.is_function {
			continue
		}
		// An empty function with no parameters is almost always an implicit
		// declaration the C front end could not resolve (malloc, calloc, ...).
		// Emitting it as a real V function with the wrong signature is worse
		// than a comment, so leave it as a TODO extern declaration.
		if obj.body.len == 0 && obj.params.len == 0 {
			lines << '// TODO: extern declaration needed for ${obj.name} (e.g. fn C.${obj.name}(...))'
			lines << ''
			continue
		}
		mut in_main := obj.name == 'main'
		mut params := []string{}
		for param in obj.params {
			params << '${v_safe_name(param.name)} ${v_type(param.ty)}'
		}
		ret := if obj.name == 'main' {
			'void'
		} else if obj.ty != unsafe { nil } && obj.ty.kind == .func {
			v_type(obj.ty.ret_type)
		} else {
			'void'
		}
		lines << 'fn ${v_safe_name(obj.name)}(${params.join(', ')}) ${ret} {'
		for local in obj.locals {
			if local.name == '' || local.name == '__alloca_size__' {
				continue
			}
			mut is_param := false
			for param in obj.params {
				if param.name == local.name {
					is_param = true
					break
				}
			}
			if is_param {
				continue
			}
			lines << '\tmut ${v_safe_name(local.name)} := ${v_zero(local.ty)}'
		}
		if obj.body.len > 0 {
			for st in obj.body {
				rendered := v_stmt(st, in_main)
				for line in rendered.split('\n') {
					if line != '' {
						lines << '\t' + line
					}
				}
			}
		}
		lines << '}'
		lines << ''
	}

	return lines.join('\n')
}

fn vemit_collect_obj(obj &ast.Obj, mut seen map[string]bool, mut out []string) {
	vemit_collect_type(obj.ty, mut seen, mut out)
	for param in obj.params {
		vemit_collect_type(param.ty, mut seen, mut out)
	}
	for local in obj.locals {
		vemit_collect_type(local.ty, mut seen, mut out)
	}
}

fn vemit_collect_type(t &ast.Type, mut seen map[string]bool, mut out []string) {
	if t == unsafe { nil } {
		return
	}
	match t.kind {
		.struct_, .union_ {
			name := if t.tag != '' {
				v_safe_name(t.tag)
			} else if t.name != '' {
				v_safe_name(t.name)
			} else {
				''
			}
			cap_name := if name != '' { name[0..1].to_upper() + name[1..] } else { '' }
			if cap_name != '' && !(cap_name in seen) {
				seen[cap_name] = true
				mut fields := []string{}
				for m in t.members {
					vemit_collect_type(m.ty, mut seen, mut out)
					fields << (if m.is_bitfield {
						'mut ' + v_safe_name(m.name) + ' ' + v_type(m.ty) + ' // bitfield: ' + m.bit_width.str() + ' bits'
					} else {
						'mut ' + v_safe_name(m.name) + ' ' + v_type(m.ty)
					})
				}
				keyword := if t.kind == .union_ { 'struct /* union */' } else { 'struct' }
				mut body := []string{}
				for f in fields {
					body << '\t' + f
				}
				out << '${keyword} ${cap_name} {\n' + body.join('\n') + '\n}'
			}
			for m in t.members {
				vemit_collect_type(m.ty, mut seen, mut out)
			}
		}
		.enum_ {
			name := if t.tag != '' {
				v_safe_name(t.tag)
			} else if t.origin != unsafe { nil } && t.origin.name != '' {
				v_safe_name(t.origin.name)
			} else if t.name != '' {
				v_safe_name(t.name)
			} else {
				''
			}
			if name != '' && !(name in seen) {
				seen[name] = true
				out << '// enum ${name} { ... }  (members not translated)'
			}
		}
		.array, .vla { vemit_collect_type(t.base, mut seen, mut out) }
		.func {
			vemit_collect_type(t.base, mut seen, mut out)
			vemit_collect_type(t.ret_type, mut seen, mut out)
			for p in t.params {
				vemit_collect_type(p, mut seen, mut out)
			}
		}
		else {}
	}
}

fn v_type(t &ast.Type) string {
	if t == unsafe { nil } {
		return 'void'
	}
	match t.kind {
		.basic {
			return match t.basic {
				.void_ { 'void' }
				.bool_ { 'bool' }
				.char_ {
					if t.is_unsigned { 'u8' } else { 'i8' }
				}
				.short_ {
					if t.is_unsigned { 'u16' } else { 'i16' }
				}
				.int_ { 'int' }
				.long_ {
					if t.size <= 4 { 'int' } else { 'i64' }
				}
				.llong_ { 'i64' }
				.float_ { 'f32' }
				.double_, .ldouble_ { 'f64' }
				.enum_ { 'int' }
				else { 'int' }
			}
		}
		.pointer { return '&' + v_type(t.base) }
		.array {
			if t.array_len >= 0 {
				return '[${t.array_len}]' + v_type(t.base)
			}
			return '[]' + v_type(t.base)
		}
		.vla { return '[]' + v_type(t.base) }
		.func {
			mut params := []string{}
			for p in t.params {
				params << v_type(p)
			}
			ret := v_type(t.ret_type)
			return 'fn (${params.join(', ')}) ${ret}'
		}
		.struct_ {
			mut name := ''
			if t.tag != '' {
				name = v_safe_name(t.tag)
			} else if t.origin != unsafe { nil } && t.origin.name != '' {
				name = v_safe_name(t.origin.name)
			} else if t.name != '' {
				name = v_safe_name(t.name)
			}
			if name != '' {
				// V requires type names to start with an uppercase letter.
				name = name[0..1].to_upper() + name[1..]
			}
			if name != '' {
				return name
			}
			return 'struct { }'
		}
		.union_ {
			mut name := ''
			if t.tag != '' {
				name = v_safe_name(t.tag)
			} else if t.origin != unsafe { nil } && t.origin.name != '' {
				name = v_safe_name(t.origin.name)
			} else if t.name != '' {
				name = v_safe_name(t.name)
			}
			if name != '' {
				name = name[0..1].to_upper() + name[1..]
			}
			if name != '' {
				return name
			}
			return 'struct { }'
		}
		.enum_ { return 'int' }
		.plugin {
			// No V spelling exists; keep the output compilable but attributable
			// rather than silently mistyping it as `int`.
			return 'int /* plugin(' + t.lang + ':' + t.plugin + ') */'
		}
		else { return 'int' }
	}
}

fn v_safe_name(s string) string {
	// Sanitize characters that are not valid in a V identifier. C allows far more
	// in identifiers than V does, and anonymous globals are named `.L..N`.
	mut out := ''
	for c in s {
		if c >= `A` && c <= `Z` {
			out += (c + 32).ascii_str()
		} else if (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`) || c == `_` {
			out += c.ascii_str()
		} else {
			out += '_'
		}
	}
	if out.len == 0 {
		out = '_'
	}
	if out.len == 0 || (out[0] >= `0` && out[0] <= `9`) || out[0] == `_` {
		out = 'g' + out
	}
	// keyword check on sanitized name
	match out {
		'fn', 'mut', 'struct', 'enum', 'union', 'interface', 'type', 'match', 'if', 'else',
		'for', 'in', 'return', 'break', 'continue', 'goto', 'defer', 'assert', 'unsafe',
		'shared', 'lock', 'rlock', 'go', 'spawn', 'select', 'chan', 'const', 'pub', 'import',
		'module', 'as', 'is', 'or', 'none', 'true', 'false', 'nil' {
			return 'c_' + out
		}
		else {
			if out == '' {
				return '_'
			}
			return out
		}
	}
}

fn v_stmts(nodes []&ast.Node, in_main bool) string {
	mut out := []string{}
	for n in nodes {
		r := v_stmt(n, in_main)
		if r != '' && r != '0;' {
			out << r
		}
	}
	return out.join('\n')
}

fn v_stmt(n &ast.Node, in_main bool) string {
	if n == unsafe { nil } {
		return ''
	}
	match n.kind {
		.null_stmt { return '' }
		.decl_stmt { return '' }
		.expr_stmt {
			if n.lhs != unsafe { nil } {
				if n.lhs.kind == .comma {
					mut parts := []string{}
					// Flatten nested commas so every assignment in an
					// initializer (or comma expression) is emitted, not just
					// the last one.
					mut stack := [n.lhs]
					for stack.len > 0 {
						cur := stack.pop()
						if cur.kind == .comma {
							stack << cur.lhs
							stack << cur.rhs
						} else {
							r := v_expr(cur)
							if r != '' && r != '0' && !r.starts_with('/*expr') {
								parts << r + ';'
							}
						}
					}
					// stack is LIFO; reverse to source order.
					parts = parts.reverse()
					return parts.join('\n')
				}
				return v_expr(n.lhs) + ';'
			}
			return ';'
		}
		.assign { return v_expr(n) + ';' }
		.return_ {
			if in_main && n.lhs != unsafe { nil } {
				// V's main returns void, so a value-returning `return` becomes
				// an explicit exit to preserve the process exit code.
				return 'exit(' + v_expr(n.lhs) + ')'
			}
			if n.lhs != unsafe { nil } {
				return 'return ' + v_expr(n.lhs)
			}
			return 'return'
		}
		.if_ {
			mut s := 'if ' + v_expr(n.cond) + ' {\n'
			if n.then != unsafe { nil } && n.then.kind == .block_ {
				s += indent_block(v_stmts(n.then.body, in_main))
			} else if n.then != unsafe { nil } {
				s += indent_block(v_stmt(n.then, in_main))
			}
			s += '\n}'
			if n.els != unsafe { nil } {
				// Render a trailing `else if` when the else branch is itself an if.
				if n.els.kind == .if_ {
					s += ' else ' + v_stmt(n.els, in_main)
				} else if n.els.kind == .block_ {
					s += ' else {\n'
					s += indent_block(v_stmts(n.els.body, in_main))
					s += '\n}'
				} else {
					s += ' else {\n'
					s += indent_block(v_stmt(n.els, in_main))
					s += '\n}'
				}
			}
			return s
		}
		.for_ {
			mut init := ''
			if n.init != unsafe { nil } {
				if n.init.kind == .block_ {
					// declaration block: render first non-trivial statement
					for stmt in n.init.body {
						r := v_stmt(stmt, in_main)
						if r != '' && r != '0;' {
							init = r
							if init.ends_with(';') {
								init = init[..init.len - 1]
							}
							break
						}
					}
				} else {
					init = v_expr(n.init)
				}
			}
			mut cond := ''
			if n.cond != unsafe { nil } {
				cond = v_expr(n.cond)
			}
			mut inc := ''
			if n.inc != unsafe { nil } {
				inc_raw := v_expr(n.inc)
				if inc_raw.contains('tmp_') {
					// Postfix ++/-- was rewritten into a pointer dance; recover
					// the loop variable from the init and emit a readable inc.
					mut var_name := 'i'
					if n.init != unsafe { nil } {
						if n.init.kind == .assign {
							var_name = v_expr(n.init.lhs)
						} else if n.init.kind == .block_ {
							for st in n.init.body {
								if st.kind == .expr_stmt && st.lhs != unsafe { nil } && st.lhs.kind == .assign {
									var_name = v_expr(st.lhs.lhs)
									break
								}
							}
						}
					}
					if inc_raw.contains('+ 1') {
						inc = var_name + '++'
					} else if inc_raw.contains('- 1') {
						inc = var_name + '--'
					} else {
						inc = '/* inc */'
					}
				} else {
					inc = inc_raw
				}
			}
			mut s := 'for ' + init + '; ' + cond + '; ' + inc + ' {\n'
			if n.then != unsafe { nil } && n.then.kind == .block_ {
				s += indent_block(v_stmts(n.then.body, in_main))
			} else if n.then != unsafe { nil } {
				s += indent_block(v_stmt(n.then, in_main))
			}
			s += '\n}'
			return s
		}
		.block_ {
			mut s := '{\n'
			s += '\n}'
			return s
		}
		.comma {
			mut s := v_stmt(n.lhs, in_main)
			rhs := v_stmt(n.rhs, in_main)
			if rhs != '' {
				if s != '' {
					s += '\n'
				}
				s += rhs
			}
			return s
		}
		.goto_ {
			if n.is_break { return 'break' }
			if n.is_continue { return 'continue' }
			return '// goto ' + v_safe_name(n.label_name)
		}
		.label { return v_safe_name(n.label_name) + ':' }
		.switch_ {
			mut s := 'match ' + v_expr(n.cond) + ' {\n'
			for c in n.cases {
				s += '\t' + v_stmt(c, in_main) + '\n'
			}
			if n.default_case != unsafe { nil } {
				s += '\telse {\n'
				s += indent_block(v_stmt(n.default_case, in_main))
				s += '\n\t}\n'
			}
			s += '}'
			return s
		}
		.case_ {
			// case node body is []&Node? check: case_ has body []&Node yes
			mut s := v_case_label(n) + ' {\n'
			s += indent_block(v_stmts(n.body, in_main))
			s += '\n}'
			return s
		}
		.do_ {
			mut s := 'for {\n'
			if n.then != unsafe { nil } && n.then.kind == .block_ {
				s += indent_block(v_stmts(n.then.body, in_main))
			} else if n.then != unsafe { nil } {
				s += indent_block(v_stmt(n.then, in_main))
			}
			s += '\n\tif !(' + v_expr(n.cond) + ') { break }'
			s += '\n}'
			return s
		}
		else { return '// stmt ' + int(n.kind).str() }
	}
}

fn v_case_label(n &ast.Node) string {
	if n.begin == n.end {
		return n.begin.str() + ' {'
	}
	return '${n.begin}...${n.end} {'
}

fn v_expr(n &ast.Node) string {
	if n == unsafe { nil } {
		return '/*nil*/'
	}
	// Unwrap expression statements.
	if n.kind == .expr_stmt && n.lhs != unsafe { nil } {
		return v_expr(n.lhs)
	}
	match n.kind {
		.null_expr { return '0' }
		.num {
			if n.ty != unsafe { nil } && (n.ty.basic == .float_ || n.ty.basic == .double_ || n.ty.basic == .ldouble_) {
				return n.fval.str()
			}
			// char literal detection via token quotes
			if n.tok.kind == .num_ && n.tok.text.len >= 2 && n.tok.text[0] == `'` {
				return "r'${n.tok.text[1..n.tok.text.len - 1]}'" // V rune literal? maybe `r'a'`? V uses `r'a'`? Actually V rune literal is `r'a'`? V char is `u8`? Use quoted.
			}
			return n.num.str()
		}
		.var_ref {
			if n.var != unsafe { nil } {
				if is_string_global(n.var) {
					return v_string_literal(n.var.init_data)
				}
				return v_safe_name(n.var.name)
			}
			return '/*var*/'
		}
		.add { return '(' + v_expr(n.lhs) + ' + ' + v_expr(n.rhs) + ')' }
		.sub { return '(' + v_expr(n.lhs) + ' - ' + v_expr(n.rhs) + ')' }
		.mul { return '(' + v_expr(n.lhs) + ' * ' + v_expr(n.rhs) + ')' }
		.div { return '(' + v_expr(n.lhs) + ' / ' + v_expr(n.rhs) + ')' }
		.mod { return '(' + v_expr(n.lhs) + ' % ' + v_expr(n.rhs) + ')' }
		.neg { return '-(' + v_expr(n.lhs) + ')' }
		.bit_and { return '(' + v_expr(n.lhs) + ' & ' + v_expr(n.rhs) + ')' }
		.bit_or { return '(' + v_expr(n.lhs) + ' | ' + v_expr(n.rhs) + ')' }
		.bit_xor { return '(' + v_expr(n.lhs) + ' ^ ' + v_expr(n.rhs) + ')' }
		.shl { return '(' + v_expr(n.lhs) + ' << ' + v_expr(n.rhs) + ')' }
		.shr { return '(' + v_expr(n.lhs) + ' >> ' + v_expr(n.rhs) + ')' }
		.eq { return '(' + v_expr(n.lhs) + ' == ' + v_expr(n.rhs) + ')' }
		.ne { return '(' + v_expr(n.lhs) + ' != ' + v_expr(n.rhs) + ')' }
		.lt { return '(' + v_expr(n.lhs) + ' < ' + v_expr(n.rhs) + ')' }
		.le { return '(' + v_expr(n.lhs) + ' <= ' + v_expr(n.rhs) + ')' }
		.assign {
			// Array element assignment `*(arr + (i * 4)) = v` is not legal V;
			// render it as `arr[i] = v`.
			mut add_node := n.lhs.lhs
			for add_node != unsafe { nil } && add_node.kind == .cast {
				add_node = add_node.lhs
			}
			mut base_expr := ''
			if add_node != unsafe { nil } && add_node.kind == .add
				&& add_node.lhs != unsafe { nil } {
				mut b := add_node.lhs
				for b != unsafe { nil } && b.kind == .cast {
					b = b.lhs
				}
				if b != unsafe { nil } && (b.kind == .var_ref || b.kind == .member) {
					base_expr = v_expr(b)
				}
			}
			mut mul_node := &ast.Node(unsafe { nil })
			if add_node != unsafe { nil } && add_node.kind == .add
				&& add_node.rhs != unsafe { nil } {
				mut r := add_node.rhs
				for r != unsafe { nil } && r.kind == .cast {
					r = r.lhs
				}
				if r != unsafe { nil } && r.kind == .mul {
					mul_node = r
				}
			}
			if base_expr != '' && mul_node != unsafe { nil } && n.lhs != unsafe { nil } && n.lhs.kind == .deref {
				mut idx := v_expr(mul_node.lhs)
				return 'unsafe { ' + base_expr + '[' + idx + '] = ' + v_expr(n.rhs) + ' }'
			}
			if n.lhs != unsafe { nil } && n.lhs.kind == .deref {
				return 'unsafe { ' + v_expr(n.lhs) + ' = ' + v_expr(n.rhs) + ' }'
			}
			return v_expr(n.lhs) + ' = ' + v_expr(n.rhs)
		}
		.cond_expr {
			return 'if ' + v_expr(n.cond) + ' { ' + v_expr(n.then) + ' } else { ' + v_expr(n.els) + ' }'
		}
		.comma { return v_expr(n.rhs) }
		.member {
			mut name := ''
			if m := n.member {
				name = m.name
			}
			// V auto-dereferences pointers for field access, so `p->x` (which is
			// `(*p).x` here) renders as `p.x` rather than `*p.x`.
			mut base := n.lhs
			if base != unsafe { nil } && base.kind == .deref {
				base = base.lhs
			}
			return v_expr(base) + '.' + v_safe_name(name)
		}
		.addr { return '&' + v_expr(n.lhs) }
		.deref {
			// Array subscript lowers to `*(base + index * stride)` in this
			// generator; render it as `base[index]` so the V side is legal.
			mut add_node := n.lhs
			for add_node != unsafe { nil } && add_node.kind == .cast {
				add_node = add_node.lhs
			}
			if add_node != unsafe { nil } && add_node.kind == .add {
				mut base := add_node.lhs
				for base != unsafe { nil } && base.kind == .cast {
					base = base.lhs
				}
				mut mul_node := add_node.rhs
				for mul_node != unsafe { nil } && mul_node.kind == .cast {
					mul_node = mul_node.lhs
				}
				if base != unsafe { nil } && base.kind == .var_ref && base.var != unsafe { nil }
					&& mul_node != unsafe { nil } && mul_node.kind == .mul {
					mut idx := v_expr(mul_node.lhs)
					name := v_safe_name(base.var.name)
					return '${name}[${idx}]'
				}
			}
			return '*' + v_expr(n.lhs)
		}
		.not { return '!' + v_expr(n.lhs) }
		.bit_not { return '~' + v_expr(n.lhs) }
		.log_and { return '(' + v_expr(n.lhs) + ' && ' + v_expr(n.rhs) + ')' }
		.log_or { return '(' + v_expr(n.lhs) + ' || ' + v_expr(n.rhs) + ')' }
		.funcall {
			mut name := '/*call*/'
			if n.lhs != unsafe { nil } && n.lhs.kind == .var_ref && n.lhs.var != unsafe { nil } {
				obj := n.lhs.var
				if obj.body.len == 0 && obj.params.len == 0 {
					name = 'C.' + v_safe_name(obj.name)
				} else {
					name = v_safe_name(obj.name)
				}
			} else if n.lhs != unsafe { nil } {
				name = v_expr(n.lhs)
			}
			mut args := []string{}
			for i, a in n.args {
				mut arg_node := a
				for arg_node != unsafe { nil } && arg_node.kind == .cast {
					arg_node = arg_node.lhs
				}
				mut rendered := v_expr(a)
				// V does not decay arrays to pointers; pass the address of
				// the first element when the callee expects a pointer.
				if arg_node != unsafe { nil } && arg_node.kind == .var_ref && arg_node.var != unsafe { nil } && arg_node.var.ty != unsafe { nil } && arg_node.var.ty.kind == .array
					&& n.lhs != unsafe { nil } && n.lhs.ty != unsafe { nil }
					&& i < n.lhs.ty.params.len && n.lhs.ty.params[i].kind == .pointer {
					rendered = '&' + v_safe_name(arg_node.var.name) + '[0]'
				}
				args << rendered
			}
			return '${name}(${args.join(', ')})'
		}
		.cast { return v_expr(n.lhs) }
		.compound_literal { return '/*compound_literal*/' }
		.stmt_expr { return '0 /* stmt_expr */' }
		.vla_ptr { return v_safe_name(n.var.name) }
		.va_arg_ { return '/*va_arg*/' }
		.va_start_ { return '/*va_start*/' }
		.goto_expr { return '/*goto_expr*/' }
		else { return '/*expr ' + int(n.kind).str() + '*/' }
	}
}

// is_string_global reports whether obj is an anonymous global holding a
// NUL-terminated byte string, which is what string_literal_expr creates.
// Such globals are emitted as V string constants rather than byte arrays.
fn is_string_global(obj &ast.Obj) bool {
	if obj == unsafe { nil } || !obj.is_definition || obj.is_function {
		return false
	}
	if !obj.name.starts_with('.L..') {
		return false
	}
	if obj.init_data.len < 2 {
		return false
	}
	// Must be NUL-terminated.
	if obj.init_data[obj.init_data.len - 1] != 0 {
		return false
	}
	// Every byte before the terminator must be printable or a common escape.
	for i in 0 .. obj.init_data.len - 1 {
		b := obj.init_data[i]
		if b == 0 {
			return false // embedded NUL -> not a simple string
		}
		if b < 32 || b == 127 {
			// allow \t \n \r only
			if b != 9 && b != 10 && b != 13 {
				return false
			}
		}
	}
	return true
}

// v_string_literal renders a NUL-terminated byte buffer as a V string literal.
fn v_string_literal(buf []u8) string {
	mut out := '"'
	for i in 0 .. buf.len - 1 {
		b := buf[i]
		match b {
			`"` { out += '\\"' }
			`\\` { out += '\\\\' }
			`\n` { out += '\\n' }
			`\t` { out += '\\t' }
			`\r` { out += '\\r' }
			else {
				if b >= 32 && b < 127 {
					out += b.ascii_str()
				} else {
					out += '\\x${b:02x}'
				}
			}
		}
	}
	out += '"'
	return out
}

fn v_zero(t &ast.Type) string {
	if t == unsafe { nil } {
		return '0'
	}
	match t.kind {
		.pointer {
			if t.base != unsafe { nil } {
				return '&' + v_type(t.base) + '(unsafe { nil })'
			}
			return 'unsafe { nil }'
		}
		.basic {
			if t.basic == .float_ || t.basic == .double_ || t.basic == .ldouble_ {
				return '0.0'
			}
			return '0'
		}
		.struct_, .union_ { return '${v_type(t)}{}' }
		.array {
			if t.array_len >= 0 {
				return '[${t.array_len}]${v_type(t.base)}{}'
			}
			return '[]${v_type(t.base)}{}'
		}
		else { return '0' }
	}
}

fn indent_block(s string) string {
	if s == '' {
		return ''
	}
	mut out := []string{}
	for line in s.split('\n') {
		if line == '' {
			out << '\t' + line
		} else {
			out << '\t' + line
		}
	}
	return out.join('\n')
}
