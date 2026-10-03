module vcc

import ast

// backslash and hash are named constants rather than literals.
//
// A backtick literal containing a bare backslash is not valid in this V build, and
// `##` is two characters, which a character literal cannot hold. Naming both keeps
// the escaping out of the string handling below, where a mistake would be silent.
const bs = u8(92)
const hash = '#'
const hashhash = '##'

// Phase 2 of the preprocessor: macro expansion.
//
// This half is deliberately separate from the directive half. Phase 1 has already
// removed every `#` line and every token in a dead `#if` branch, so this file never
// has to ask whether a token is live, and a `#` produced by a macro cannot be
// mistaken for a directive.
//
// The expansion algorithm is the standard one: walk the stream, and when a macro
// name is found, substitute its arguments into its body and rescan the result. The
// one subtlety is the recursion guard, below.

/// builtin_token builds the token for a computed macro such as `__LINE__`.
fn (mut p Preprocessor) builtin_token(m Macro, tok ast.Token, path string) ast.Token {
	value := match m.builtin {
		.file { path }
		.line { i64(tok.line.disp_line).str() }
		.counter {
			p.counter++
			p.counter.str()
		}
		else { '0' }
	}
	return ast.Token{
		kind:      .str_
		text:      '"${value}"'
		// The value is a string token so that it can be pasted and compared without the
		// parser needing to know it came from a builtin; the type checker converts it.
		len:       value.len + 2
		loc:       tok.loc
		line:      tok.line
		str_data:  value.bytes()
		at_bol:    tok.at_bol
		has_space: tok.has_space
	}
}

// expand rescans a token stream, replacing every macro invocation.
fn (mut p Preprocessor) expand(toks []ast.Token, path string) []ast.Token {
	mut out := []ast.Token{}
	mut i := 0
	for i < toks.len {
		tok := toks[i]
		if tok.kind != .ident {
			out << tok
			i++
			continue
		}
		idx := p.find_index(tok.text) or {
			out << tok
			i++
			continue
		}
		m := p.macros[idx]
		if m.builtin != .none {
			out << p.builtin_token(m, tok, path)
			i++
			continue
		}
		// The recursion guard. A macro already being expanded is not expanded again,
		// so `#define A B` / `#define B A` terminates instead of looping, and a macro
		// that legitimately mentions itself stops rather than recursing.
		if m.is_expanding {
			out << tok
			i++
			continue
		}
		if m.is_func {
			open := next_significant(toks, i + 1)
			if open < 0 || toks[open].text != '(' {
				// A function-like macro name not followed by `(` is an ordinary
				// identifier. This is what keeps `#define MAX 1` from being invoked by
				// an unrelated bracket.
				out << tok
				i++
				continue
			}
			parsed := collect_args(toks, open)
			if parsed.close < 0 {
				p.errorf(tok.line.disp_line, 'unterminated argument list for ${m.name}')
				out << tok
				i++
				continue
			}
			mut substituted, arg_count := p.substitute(m, parsed.list,
				tok.line.disp_line)
			if arg_count < 0 {
				// A wrong argument count is reported by `substitute`; the macro is left
				// unexpanded rather than guessed at.
				out << tok
				i = parsed.close
				continue
			}
			p.macros[idx].is_expanding = true
			substituted = p.expand(stamp_line(substituted, tok.line.disp_line), path)
			p.macros[idx].is_expanding = false
			out << substituted
			i = parsed.close
			continue
		}
		mut substituted, _ := p.substitute(m, [][]ast.Token{}, tok.line.disp_line)
		p.macros[idx].is_expanding = true
		substituted = p.expand(stamp_line(substituted, tok.line.disp_line), path)
		p.macros[idx].is_expanding = false
		out << substituted
		i++
	}
	return out
}

// next_significant returns the index of the next token that is not whitespace-only,
// or -1. Newline tokens do not appear in the phase 2 stream because the tokenizer
// folds them into `has_space`, so this is currently the identity; it exists so the
// intent is explicit if that ever changes.
fn next_significant(toks []ast.Token, from int) int {
	mut i := from
	for i < toks.len {
		return i
	}
	return -1
}

// Args is the result of reading a macro invocation's argument list.
struct Args {
mut:
	// close is the index just past the matching `)`, or -1 when the list was never
	// closed.
	close int
	// list holds each argument as its own token list, because an argument is expanded
	// as a unit rather than token by token.
	list [][]ast.Token
}

// collect_args reads a parenthesised argument list starting at the `(` at `open`.
fn collect_args(toks []ast.Token, open int) Args {
	mut args := Args{
		close: -1
		list:  [][]ast.Token{}
	}
	mut cur := []ast.Token{}
	mut depth := 0
	mut i := open
	for i < toks.len {
		t := toks[i]
		if t.text == '(' {
			depth++
			if depth == 1 {
				i++
				continue
			}
		} else if t.text == ')' {
			depth--
			if depth == 0 {
				// A trailing comma produces one empty argument, which must be kept:
				// `F(a, )` passes two arguments, the second empty.
				if cur.len > 0 || args.list.len > 0 {
					args.list << cur
				}
				args.close = i + 1
				return args
			}
		} else if t.text == ',' && depth == 1 {
			args.list << cur
			cur = []
			i++
			continue
		}
		cur << t
		i++
	}
	return args
}

// `m.va_name` is empty for a plain `...`, so the check names `__VA_ARGS__` as well.
// Doing it this way means one rule covers both the standard spelling and the GNU
// named form.
fn is_va(m Macro, name string) bool {
	if !m.is_variadic {
		return false
	}
	return name == '__VA_ARGS__' || (m.va_name.len > 0 && name == m.va_name)
}

// substitute replaces a macro's parameters in its body with the given arguments.
//
// It returns the substituted token list and, for a function-like macro, the
// argument count, or -1 when that count is wrong.
//
// Three cases are handled distinctly, and conflating them is the usual source of
// misexpansion:
//   - `# param`          stringizes the *unexpanded* argument
//   - `a ## b`           pastes, using the *unexpanded* argument
//   - a bare parameter   substitutes the *expanded* argument
fn (mut p Preprocessor) substitute(m Macro, args [][]ast.Token, line int) ([]ast.Token, int) {
	if !m.is_func {
		mut out := []ast.Token{}
		for t in m.body {
			// A `#` in an object-like macro's body has no operand to stringify, so it
			// is an ordinary token.
			out << t
		}
		return out, 0
	}
	mut named := args.len
	mut va_args := []ast.Token{}
	if m.is_variadic {
		// Everything at and beyond the named parameters is variadic.
		want := m.params.len
		if named < want {
			p.errorf(line, 'macro ${m.name} requires ${want} arguments, but ${named} given')
			return []ast.Token{}, -1
		}
		for i in want .. named {
			if i > want {
				va_args << ast.Token{
					kind: .punct
					text: ','
				}
			}
			va_args << args[i]
		}
		named = want
	} else {
		if named != m.params.len {
			p.errorf(line, 'macro ${m.name} requires ${m.params.len} arguments, but ${named} given')
			return []ast.Token{}, -1
		}
	}
	mut out := []ast.Token{}
	mut body := m.body.clone()
	mut i := 0
	for i < body.len {
		t := body[i]
		// `# param`
		if t.text == hash && i + 1 < body.len {
			param := body[i + 1]
			if idx := param_index(m, param.text) {
				arg := if idx < named { args[idx] } else { []ast.Token{} }
				out << stringify(arg)
				i += 2
				continue
			}
			if is_va(m, param.text) {
				out << stringify(va_args)
				i += 2
				continue
			}
		}
		// `lhs ## rhs`
		if i + 1 < body.len && body[i + 1].text == hashhash && i + 2 < body.len {
			lhs := t
			rhs := body[i + 2]
			// GNU's `, ## __VA_ARGS__` is *not* a paste. It is a comma that disappears
			// when the variadic part is empty, and glibc headers depend on it. Treating
			// it as a paste would glue the comma to the first argument, so it is handled
			// separately and never reaches `paste`.
			if m.is_variadic && is_va(m, rhs.text) {
				if va_args.len == 0 {
					if out.len > 0 && out[out.len - 1].text == ',' {
						out.delete(out.len - 1)
					}
				} else {
					out << lhs
					out << va_args.clone()
				}
				i += 3
				continue
			}
			mut l_tokens := [lhs].clone()
			if idx := param_index(m, lhs.text) {
				l_tokens = if idx < named { args[idx].clone() } else { []ast.Token{} }
			}
			mut r_tokens := [rhs].clone()
			if idx := param_index(m, rhs.text) {
				r_tokens = if idx < named { args[idx].clone() } else { []ast.Token{} }
			}
			out << paste(l_tokens, r_tokens)
			i += 3
			continue
		}
		if idx := param_index(m, t.text) {
			if idx < named {
				out << p.expand(args[idx], '')
			}
			i++
			continue
		}
		if is_va(m, t.text) {
			out << p.expand(va_args, '')
			i++
			continue
		}
		out << t
		i++
	}
	return out, named
}

// stamp_line rewrites every token's position to one line.
//
// A macro body's tokens come from `tokenize_fragment` and therefore all sit on line 1.
// Without this, every diagnostic inside a macro expansion points at the top of the
// file instead of at the invocation, which is the single most misleading thing a
// preprocessor can do. The invocation site is the only position that is meaningful.
fn stamp_line(toks []ast.Token, line int) []ast.Token {
	mut out := []ast.Token{}
	for t in toks {
		mut stamped := t
		stamped.line = ast.Line{
			disp_line: line
			disp_col:  1
		}
		out << stamped
	}
	return out
}

// param_index returns a parameter's position, or none when the name is not one.
fn param_index(m Macro, name string) ?int {
	for i, param in m.params {
		if param == name {
			return i
		}
	}
	return none
}

// stringify renders an argument as a string literal, which is what `#` produces.
//
// The spelling is reconstructed from the tokens with a single space wherever the
// token had preceding whitespace, which is the standard's rule and the only reason
// `has_space` is recorded during tokenization.
fn stringify(arg []ast.Token) ast.Token {
	mut text := '"'
	for i, t in arg {
		if i > 0 && t.has_space {
			text += ' '
		}
		if t.text == '"' || t.text == bs.str() {
			text += bs.str()
		}
		text += t.text
	}
	text += '"'
	return ast.Token{
		kind:     .str_
		text:     text
		len:      text.len
		str_data: string_body(text)
	}
}

// string_body strips the surrounding quotes and undoes the escaping added by
// `stringify`.
fn string_body(text string) []u8 {
	if text.len < 2 {
		return []u8{}
	}
	mut out := []u8{}
	mut i := 1
	for i < text.len - 1 {
		if text[i] == bs && i + 1 < text.len - 1 {
			i++
		}
		out << text[i]
		i++
	}
	return out
}

// paste concatenates two token sequences and re-lexes the result, following C11
// 6.10.3.3.
//
// The result must be a single valid token. When the joined text re-lexes as more
// than one token the behaviour is undefined; the re-lexed tokens are emitted anyway,
// because that is closer to the intent than a single identifier that the parser will
// later reject with a worse message.
fn paste(lhs []ast.Token, rhs []ast.Token) ast.Token {
	joined := concat_text(lhs) + concat_text(rhs)
	toks := tokenize_fragment(joined)
	mut out := []ast.Token{}
	for t in toks {
		if t.kind == .eof {
			continue
		}
		out << t
	}
	if out.len == 1 {
		return out[0]
	}
	return ast.Token{
		kind: .ident
		text: joined
		len:  joined.len
	}
}

// concat_text renders a token sequence back to its spelling, inserting a space only
// where one is needed to keep the tokens apart.
fn concat_text(toks []ast.Token) string {
	mut out := ''
	for t in toks {
		if out.len > 0 && needs_space(out, t.text) {
			out += ' '
		}
		out += t.text
	}
	return out
}

// needs_space reports whether a separator is required between two adjacent spellings.
fn needs_space(left string, right string) bool {
	if left.len == 0 || right.len == 0 {
		return false
	}
	a := left[left.len - 1]
	b := right[0]
	return is_ident_byte(a) && is_ident_byte(b)
}
