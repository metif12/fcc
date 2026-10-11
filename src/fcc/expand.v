module fcc

import ast
import os
import time

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
		// [C11 6.10.8.1p2] the value starts at 0 and increments after each use: "a new
		// integer constant ... beginning with 0". Incrementing *before* reading — which
		// this did — made the first use 1, and chibicc's macro.c asserts on 0, 1, 2.
		.counter {
			value := p.counter.str()
			p.counter++
			value
		}
		// [C11 6.10.8p1] `__STDC__` is the integer constant 1, and the decimal spelling
		// of the implementation's conformance. gcc prints a bare `1` with no quotes, and
		// `strlen` of it is 1, which is what chibicc's macro.c asserts.
		.stdc { '1' }
		.date { date_spelling(time.now()) }
		.time_ { time.now().hhmmss() }
		.timestamp { timestamp_spelling(p.base_file) }
		.base_file { p.base_file }
		else { '0' }
	}
	// Most builtins are strings — a file name is text and a date is text — but
	// `__STDC__`, `__LINE__` and `__COUNTER__` are *integer constants* by [C11
	// 6.10.8p1], and every one of them has to be a number.
	//
	// Emitting `__LINE__` as a string is the defect this fixes: `int main_line1 =
	// __LINE__;` became `int main_line1 = "5";`, which initialises an `int` from the
	// address of a string literal. It compiled, linked, and ran, and produced
	// 1648275536 instead of 5 — the shape of failure this project can least afford,
	// because nothing about the diagnostic points at the builtin. Measured on chibicc's
	// macro.c 341.
	//
	// A numeric token needs both `kind` and `text`: `numeric_type` reads the spelling
	// and ignores `val`, so flipping only the kind would give the default int.
	if m.builtin in [.stdc, .line, .counter] {
		return ast.Token{
			kind:      .num_
			text:      value
			val:       value.i64()
			len:       value.len
			loc:       tok.loc
			line:      tok.line
			at_bol:    tok.at_bol
			has_space: tok.has_space
		}
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

// date_spelling renders `__DATE__`'s value: "Mmm dd yyyy".
//
// The day is space-padded, not zero-padded, which is the difference from `time`'s own
// `DD` format and what makes the field 11 characters rather than 12. Measured: gcc
// prints "Oct 10 2026" and chibicc's macro.c asserts strlen == 11.
fn date_spelling(t time.Time) string {
	return '${t.smonth()} ${t.day:2} ${t.year}'
}

// timestamp_spelling renders `__TIMESTAMP__`'s value: "Www Mmm dd hh:mm:ss yyyy".
//
// It is the *source file's modification time*, not the current time, which is what
// distinguishes it from `__DATE__` followed by `__TIME__`. Twenty-four characters, and
// the order is weekday, month, day, **time, year** — the year last, not as `__DATE__`
// spells it. Measured against gcc, which prints "Sat Oct 10 13:32:29 2026" and whose
// macro.c counterpart asserts strlen == 24.
//
// When the file cannot be stat'ed the current time is used rather than an empty string,
// because a program that compares the result against something is then wrong in an
// obvious way instead of not at all.
fn timestamp_spelling(path string) string {
	t := if st := os.stat(path) {
		time.unix(st.mtime)
	} else {
		time.now()
	}
	return '${t.weekday_str()} ${t.smonth()} ${t.day:2} ${t.hhmmss()} ${t.year}'
}

// expand rescans a token stream, replacing every macro invocation.
fn (mut p Preprocessor) expand(toks []ast.Token, path string) []ast.Token {
	mut out := []ast.Token{}
	mut i := 0
	for i < toks.len {
		tok := toks[i]
		// Keywords are looked up too, not only identifiers.
		//
		// [C11 7.1.2p2] reserves keyword-named macros only "prior to the inclusion of
		// the header", and DR 108 records the Committee's intention as allowing macros to
		// mask a keyword. Keywords become reserved in phases 7 and 8, after expansion, so
		// `#define if 5` followed by `int x = if;` is legal C and must see the 5. Measuring
		// it: gcc, gcc -pedantic-errors and tcc all accept it silently, and chibicc's
		// macro.c line 133 depends on it.
		//
		// The table is text-keyed and never inspects a token's kind, so this is the only
		// gate in the way. `#if`/`#ifdef` are unaffected — `eval_condition` tokenises and
		// evaluates without consulting the table, and `eval_ifdef` already accepts both
		// kinds.
		if tok.kind != .ident && tok.kind != .keyword {
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
		//
		// While an *argument* is being expanded the name is also recorded, because
		// [C11 6.10.3.4p2] makes that paint permanent for the enclosing replacement:
		// "These nonreplaced macro name preprocessing tokens are no longer available
		// for further replacement even if they are later (re)examined". See `painted`.
		if m.is_expanding {
			if p.collecting_paint {
				p.painted << m.name
			}
			out << tok
			i++
			continue
		}
		// [C11 6.10.3.4p2] A name an argument's expansion left unpainted stays unpainted
		// through the rescan that follows it, because the nonreplaced tokens are "no
		// longer available for further replacement even if they are later (re)examined".
		// That is what stops a self-referential macro being expanded a second time.
		if m.name in p.painted {
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
			// The paint is taken *before* substitution and released after this macro's
			// rescan, because that is the window it has to cover: `substitute` expands the
			// arguments, which is where the paint is made, and the rescan is what has to
			// respect it.
			//
			// A macro whose own substitution happens *inside* an argument's expansion does
			// not own the paint and must not release it — the caller that invoked
			// `expand_arg` does. Releasing at every level breaks mutual recursion: the
			// inner macro of `#define dbl(x) M10(x) * x` / `#define M10(x) dbl(x) + 3`
			// spent the paint meant for dbl's rescan, so `dbl(2)` became
			// `dbl(2) + 3 * 2 + 3 * 2`. Measured on chibicc's macro.c 236.
			owns_paint := !p.collecting_paint
			paint_mark := p.painted.len
			mut substituted, arg_count := p.substitute(m, parsed.list, path,
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
			if owns_paint {
				p.painted.trim(paint_mark)
			}
			// The invocation's own spacing is carried onto the first token of what it
			// became, because the spacing in the output is where the tokens ended up and
			// not where the macro name was written.
			//
			// `#define M14(x) M13(x. M12)` with `M12` an object-like macro for `foo` has a
			// space before `M12` in the body, and the stringified argument is `"bar. foo"`
			// — so `foo` has to arrive with that space. Measured on chibicc's macro.c 320.
			out << with_leading_space(substituted, tok.has_space)
			i = parsed.close
			continue
		}
		mut substituted, _ := p.substitute(m, [][]ast.Token{}, path, tok.line.disp_line)
		p.macros[idx].is_expanding = true
		substituted = p.expand(stamp_line(substituted, tok.line.disp_line), path)
		p.macros[idx].is_expanding = false
		// The invocation's own spacing, carried onto the first token of what it became —
		// as in the function-like branch above. An object-like macro is the common case:
		// `M12` in `M14(x) M13(x. M12)` with `#define M12 foo` is one.
		out << with_leading_space(substituted, tok.has_space)
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

// matching_paren returns the index of the `)` closing the `(` at `open`, or -1 when the
// list is never closed.
//
// Nesting is counted rather than assumed flat, because `__VA_OPT__`'s content is an
// arbitrary replacement list and a call or a cast inside it would otherwise close it
// early. `m.body` ends with the tokenizer's eof token, whose text is empty, so a missing
// `)` runs off the end and returns -1 instead of looping.
fn matching_paren(body []ast.Token, open int) int {
	mut depth := 0
	for i in open .. body.len {
		if body[i].text == '(' {
			depth++
		} else if body[i].text == ')' {
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// has_va_opt reports whether a token list contains `__VA_OPT__`.
fn has_va_opt(toks []ast.Token) bool {
	for t in toks {
		if t.text == '__VA_OPT__' {
			return true
		}
	}
	return false
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
//
// **An argument is substituted raw and expanded by the rescan, not expanded here.**
// Expanding it here looks equivalent and is not, because of the recursion guard: a
// pre-expanded argument has already set and cleared `is_expanding` for any macro it
// mentioned, so when `expand` rescans the substituted result that macro is expanded a
// *second* time. Measured on chibicc's macro.c:
//
//	#define M2 M2 + 3
//	#define ASSERT(x,y) assert(x,y,#y)
//	ASSERT(9, M2)
//
// is `assert(9, M2 + 3, "M2")` in C — `M2` is expanded once, and the copy of it left by
// the self-reference rule is not replaced again. Expanding the argument first gave
// `M2 + 3 + 3`, twelve instead of nine. Expanding it in the rescan instead means the
// rescan sees `M2` with the flag clear, expands it once, and paints it for the nested
// pass — which is the same single expansion, in the same place, with no flag to reset.
// `#` and `##` are unaffected: they already read `args[idx]` directly.
fn (mut p Preprocessor) substitute(m Macro, args [][]ast.Token, path string, line int) ([]ast.Token,
	int) {
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
		//
		// `...` is not one of `m.params` — `parse_params` records it as the variadic
		// flag and leaves it out — so `params.len` is already the number of *required*
		// arguments and a variadic macro may be called with none of its variadic ones.
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
		// [C23 6.10.5.1] `__VA_OPT__(content)`, present only when the variadic part is.
		//
		// The emptiness test is on a *hypothetical* substitution of `__VA_ARGS__`, so it
		// is answered by `va_args` being empty, and the content is expanded only in the
		// non-empty branch — which is the order that matters: `__VA_OPT__(EMPTY x)`
		// expands to nothing when there are no variadic arguments and to ` x` when there
		// are, and expanding the content first would make it `< x>` both ways. Measured
		// against gcc: `#define G(...) <__VA_OPT__(EMPTY x)>` gives `<>` and `< x>`.
		//
		// The content is substituted by recursing on a copy of this macro with the
		// content as its body, because it is the replacement list of the *current* macro
		// and its parameters are this macro's parameters. A single `body[i+2..close]`
		// copy would leave `x` in the output unsubstituted.
		if t.text == '__VA_OPT__' && m.is_variadic && i + 1 < body.len
			&& body[i + 1].text == '(' {
			close := matching_paren(body, i + 1)
			if close > i + 1 {
				if va_args.len > 0 {
					// [C23 6.10.5.1p3] forbids `__VA_OPT__` inside a `__VA_OPT__`, and gcc
					// diagnoses it. Left to recurse it would not terminate, so it is
					// reported rather than silently expanded or silently dropped.
					if has_va_opt(body[i + 2..close]) {
						p.errorf(line, '__VA_OPT__ may not appear inside __VA_OPT__')
					} else {
						mut inner := m
						inner.body = body[i + 2..close].clone()
						mut sub, _ := p.substitute(inner, args, path, line)
						out << sub
					}
				}
				i = close + 1
				continue
			}
		}
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
			mut joined := paste(l_tokens, r_tokens)
			i += 3
			// `x##y##z` is a chain, and one paste per position is not enough: without
			// this loop the second `##` matched no branch above and fell through to
			// `out << t`, so `paste4(1,2,3)` expanded to `12 ## 3` and the parser
			// reported `expected ",", found "##"` followed by `too many arguments`
			// against `assert`'s arity. The pasted result's last token is the left
			// operand of the next `##`, which is why the chain is walked here rather
			// than inside `paste`: the right-hand operands come from the body this
			// loop is already walking.
			for i + 1 < body.len && body[i].text == hashhash {
				mut n_tokens := [body[i + 1]].clone()
				if idx := param_index(m, body[i + 1].text) {
					n_tokens = if idx < named { args[idx].clone() } else { []ast.Token{} }
				}
				joined = paste(joined, n_tokens)
				i += 2
			}
			out << joined
			continue
		}
		if idx := param_index(m, t.text) {
			if idx < named {
				// [C11 6.10.3.1p1] the argument is macro-expanded *before* substitution,
				// "unless preceded by a # or ## preprocessing token or followed by a ##".
				// This arm is the bare one, so expansion belongs here, and `expand_arg`
				// keeps the paint an argument's own expansion left for the rescan below.
				//
				// The parameter's own spacing is applied afterwards rather than inside
				// `expand_arg`, because `expand_arg` is told nothing about the body: the
				// space that matters is the one written before `x` in `M12(foo. x)`, and
				// the invocation site has none before `bar`.
				out << with_leading_space(p.expand_arg(args[idx], path), t.has_space)
			}
			i++
			continue
		}
		if is_va(m, t.text) {
			// `__VA_ARGS__` is a parameter like any other [C11 6.10.3.1p2], and it is
			// not adjacent to `#` or `##` here, so its argument is expanded too.
			out << with_leading_space(p.expand_arg(va_args, path), t.has_space)
			i++
			continue
		}
		out << t
		i++
	}
	return out, named
}

// with_leading_space returns an argument's tokens with the spacing of its first token
// reconciled against where the parameter stood in the body.
//
// The two disagree, and `#` stringizing needs the body's answer. An argument's tokens
// carry the spacing of the *invocation site*, which for `M12(foo. x)` with `x` bound to
// `bar` says there was no space before `bar` — but the body wrote a space before `x`, and
// the stringified argument is `"foo. bar"`, not `"foo.bar"`. Measured on chibicc's
// macro.c line 311, where `#define M13(x) M12(foo. x)` must give `"foo. bar"`.
//
// OR rather than overwrite, because both sides can be the one that carried a real space.
fn with_leading_space(arg []ast.Token, param_has_space bool) []ast.Token {
	if arg.len == 0 || !param_has_space {
		return arg
	}
	mut out := arg.clone()
	mut first := out[0]
	first.has_space = true
	out[0] = first
	return out
}

// expand_arg expands a macro's argument before substitution, per [C11 6.10.3.1p1], and
// leaves the names it could not expand recorded for the rescan that follows.
//
// The recording is scoped by `collecting_paint` rather than always on, because an
// argument expansion is the *only* place a name may be legitimately left unpainted and
// still need protecting. Outside it, `#define A A` at top level expands once and a later
// use of A expands normally — gcc shows exactly that:
//
//	#define M2 M2 + 3
//	#define A(x) x
//	A(M2)          ->  M2 + 3
//	int y = M2;    ->  int y = M2 + 3;
//
// The paint expires with the macro replacement that caused it, which is what makes those
// two answers different. `painted` is cleared after that macro's rescan in `expand`.
fn (mut p Preprocessor) expand_arg(toks []ast.Token, path string) []ast.Token {
	outer := p.collecting_paint
	p.collecting_paint = true
	out := p.expand(toks, path)
	p.collecting_paint = outer
	return out
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

// paste joins the last token of the left argument with the first token of the right,
// following C11 6.10.3.3p2.
//
// Only the two boundary tokens are joined. The tokens before the last on the left and
// after the first on the right stay ordinary tokens either side, which is what makes
// `paste(1+i,3)` produce `1`, `+`, `i3` rather than the single identifier `1+i3`. This
// used to concatenate the two arguments whole, so every `x##y` whose operand held more
// than one token came out as one identifier the parser then rejected with
// `undefined variable "1+i3"` — a message about the wrong thing entirely, and the reason
// four lines of chibicc's macro.c failed.
//
// An argument with no tokens is a placemarker (p2): it contributes no boundary token, so
// `x##y` with an empty `y` is `x`. `collect_args` already represents `f(5,)` as an empty
// argument, so the placemarker rule needs no special case at the call site.
//
// Returns a list rather than a token, because a paste that is not one at a chain's end
// sits *between* other tokens: `2##x` with `x` bound to `1+2` is `21`, `+`, `2`.
fn paste(lhs []ast.Token, rhs []ast.Token) []ast.Token {
	if lhs.len == 0 {
		return rhs.clone()
	}
	if rhs.len == 0 {
		return lhs.clone()
	}
	mut out := lhs[..lhs.len - 1].clone()
	joined := lhs[lhs.len - 1].text + rhs[0].text
	toks := tokenize_fragment(joined)
	for t in toks {
		if t.kind == .eof {
			continue
		}
		out << t
	}
	out << rhs[1..].clone()
	return out
}
