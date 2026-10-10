module fcc
import os
import ast

// The preprocessor.
//
// This is the largest part of the front end and the one that does not exist at all
// in the only prior V C compiler: `lemoncmd/vcc` lists it as not implemented. It is
// also the part chibicc itself only partly implements, so this file follows the C
// standard rather than any one implementation.
//
// It runs in two phases, which is what keeps each one simple:
//
//	phase 1  directives, conditionals and `#include`
//	phase 2  macro expansion
//
// Doing it in one pass is possible but forces the directive handler and the expander
// to share mutable state over the same list, and the resulting code is quadratic.
// Splitting them also means phase 2 can be tested on its own by handing it a token
// list that never went through a directive.
//
// Design points that matter:
//
//   - Expansion works on a token list, never on text. Text-level expansion cannot
//     handle `a ## b` and would re-scan string literals.
//   - A macro is marked while it is being expanded, so a macro that mentions itself
//     directly or through a cycle stops rather than recursing forever. This is the
//     single most important property here.
//   - `#if` expressions are evaluated in phase 1, not by the parser, because they must
//     see macros the parser will never see.
//   - Diagnostics are collected rather than fatal, so one bad line does not hide the
//     rest of the file.

pub struct Preprocessor {
pub mut:
	// macros is an ordered list rather than a map so that a dump is deterministic and a
	// redefinition can replace in place.
	macros []Macro
	// cond_stack holds the state of every open `#if`, so `#else` and `#endif` can find
	// the level they belong to and an unterminated `#if` becomes a diagnosable error
	// at end of file rather than a silent acceptance.
	cond_stack []Conditional
	// quote_paths and angle_paths are the include search lists. A quoted include also
	// searches the including file's own directory, which an angled include never does.
	quote_paths []string
	angle_paths []string
	// pragma_once holds files marked `#pragma once`.
	pragma_once map[string]bool
	// pack_stack is the `#pragma pack(push, N)` stack, and packs records where each
	// change took effect so the parser can ask what was in force at a given line.
	pack_stack []int
	packs      []PackEvent
	// errors collects diagnostics instead of stopping.
	errors []string
	// counter names `__COUNTER__`.
	counter int
	// base_file is the top-level translation unit. `__BASE_FILE__` needs it, and it
	// cannot be read from the `path` an expansion is currently handed, because that
	// changes on every `#include` — inside a header, `__FILE__` is the header and
	// `__BASE_FILE__` must still be the file that was compiled.
	base_file string
	// depth bounds include nesting and expansion recursion, so a pathological file is
	// reported instead of exhausting the stack.
	depth int
}

// max_depth bounds include nesting and expansion recursion.
const max_depth = 200

// Macro is one `#define`.
pub struct Macro {
pub mut:
	name string
	// is_func distinguishes a function-like macro, which takes arguments and is only
	// invoked when its name is followed by `(`. Without that distinction `MAX` in
	// `#define MAX 1` would be invoked by any following `(`, a classic misexpansion.
	is_func bool
	params  []string
	// is_variadic marks `...` as the final parameter; va_name then names the parameter
	// the variadic arguments bind to.
	is_variadic bool
	va_name     string
	// body is the replacement list, already tokenized.
	body []ast.Token
	// builtin marks `__FILE__` and friends, whose value depends on where they are used
	// rather than being stored.
	builtin BuiltinMacro
	// is_expanding is the recursion guard. It is set while the macro's body is being
	// rescanned and cleared afterwards, so a self-referential macro stops instead of
	// looping.
	is_expanding bool
}

// BuiltinMacro names a macro computed at the point of use.
pub enum BuiltinMacro {
	none
	file
	line
	counter
	// stdc is `__STDC__`, whose value is the *number* 1 rather than a string.
	stdc
	// date, time_ and timestamp are the clock, spelled the way C spells them.
	date
	time_
	timestamp
	// base_file is `__BASE_FILE__`: the top-level translation unit, not the header the
	// use happens to sit in. `file` is the current one.
	base_file
}

// Conditional is one open `#if`.
//
// `taken` and `live` are different facts and conflating them is what inverts every
// conditional: `taken` means some branch of this level has been selected, `live`
// means the branch currently being read is one that should be emitted. For `#if 1`
// the first is true and the second is also true; for `#if 1 / #else` the level is
// `taken` but not `live`, which is how the second branch is suppressed.
struct Conditional {
pub mut:
	// taken records whether any branch of this level has been selected.
	taken bool
	// live records whether the branch currently being read should be emitted.
	live bool
	// in_else records whether this level has already seen its `#else`.
	in_else bool
	line    int
}

// Result is the outcome of preprocessing one translation unit.
pub struct Result {
pub mut:
	tokens []ast.Token
	errors []string
}

// preprocessor returns a preprocessor configured from the driver's options.
pub fn preprocessor(quote_paths []string, angle_paths []string) &Preprocessor {
	return &Preprocessor{
		macros:      []Macro{}
		cond_stack:  []Conditional{}
		quote_paths: quote_paths.clone()
		angle_paths: angle_paths.clone()
		pragma_once: map[string]bool{}
		errors:      []string{}
	}
}

// define_from_option adds a macro from a `-D` option.
//
// The value is optional: `-DFOO` defines FOO as 1 and `-DFOO=bar` as bar, which is
// what a build system generating flags expects.
pub fn (mut p Preprocessor) define_from_option(spec string) {
	if idx := spec.index('=') {
		p.define_raw(spec[..idx], false, []string{}, false, '',
			tokenize_fragment(spec[idx + 1..]))
		return
	}
	p.define_raw(spec, false, []string{}, false, '', tokenize_fragment('1'))
}

// undefine removes a macro, matching `-U`.
pub fn (mut p Preprocessor) undefine(name string) {
	p.macros = p.macros.filter(it.name != name)
}

// define_raw registers a macro whose body is already tokenized.
pub fn (mut p Preprocessor) define_raw(name string, is_func bool, params []string,
	is_variadic bool, va_name string, body []ast.Token) {
	p.macros = p.macros.filter(it.name != name)
	p.macros << Macro{
		name:        name
		is_func:     is_func
		params:      params
		is_variadic: is_variadic
		va_name:     va_name
		body:        body
		builtin:     .none
	}
}

// define_builtin registers one of the computed macros.
pub fn (mut p Preprocessor) define_builtin(name string, which BuiltinMacro) {
	p.macros = p.macros.filter(it.name != name)
	p.macros << Macro{
		name:    name
		builtin: which
	}
}

// define_builtins registers the standard computed macros.
pub fn (mut p Preprocessor) define_builtins() {
	p.define_builtin('__FILE__', .file)
	p.define_builtin('__LINE__', .line)
	p.define_builtin('__COUNTER__', .counter)
	p.define_builtin('__STDC__', .stdc)
	p.define_builtin('__DATE__', .date)
	p.define_builtin('__TIME__', .time_)
	p.define_builtin('__TIMESTAMP__', .timestamp)
	p.define_builtin('__BASE_FILE__', .base_file)
}

// lookup finds a macro by name, or returns none.
pub fn (p &Preprocessor) lookup(name string) ?Macro {
	for m in p.macros {
		if m.name == name {
			return m
		}
	}
	return none
}

// find_index returns the position of a macro in the table, so that the recursion
// guard can be set and cleared in place.
fn (mut p Preprocessor) find_index(name string) ?int {
	for i, m in p.macros {
		if m.name == name {
			return i
		}
	}
	return none
}

// is_defined reports whether a macro exists. `#ifdef` must not expand its operand, so
// this takes the raw name and nothing else.
pub fn (p &Preprocessor) is_defined(name string) bool {
	return p.lookup(name) != none
}

// errorf records a diagnostic with a line number. Processing continues so one bad
// line does not hide the rest of the file.
pub fn (mut p Preprocessor) errorf(line int, msg string) {
	p.errors << '${line}: ${msg}'
}

// run preprocesses a file, following `#include`.
//
// The expansion has already happened inside `directives`, one batch at a time, which is
// what makes a `#define` take effect at its own line. Expanding here as well would be a
// second pass over tokens whose macro names were deliberately kept — the recursion guard
// and a wrong argument count both leave one in place — and would expand them again
// against whatever the file defined last.
pub fn (mut p Preprocessor) run(path string) Result {
	src := os.read_file(path) or {
		p.errorf(0, 'cannot read ${path}')
		return Result{
			tokens: p.finish([])
			errors: p.errors.clone()
		}
	}
	p.base_file = path
	return Result{
		tokens: p.finish(strip_sentinels(p.directives(tokenize(src), path)))
		errors: p.errors.clone()
	}
}

// run_text preprocesses source with no file behind it, for tests and for `-D`-only
// runs. `path` is used for include resolution and for `__FILE__` only.
pub fn (mut p Preprocessor) run_text(src string, path string) Result {
	// A run with no file still needs a `__BASE_FILE__`, and `path` is the best answer
	// available: the alternative is the empty string, which compares equal to nothing
	// and so fails silently in any program that checks it.
	p.base_file = path
	return Result{
		tokens: p.finish(strip_sentinels(p.directives(tokenize(src), path)))
		errors: p.errors.clone()
	}
}

// finish appends the terminating eof token the parser expects, and reports any
// conditional left open.
fn (mut p Preprocessor) finish(toks []ast.Token) []ast.Token {
	if p.cond_stack.len > 0 {
		p.errorf(p.cond_stack[p.cond_stack.len - 1].line, 'unterminated #if')
	}
	p.cond_stack = []
	mut out := toks.clone()
	out << ast.Token{
		kind: .eof
		line: ast.Line{
			disp_line: 1
		}
	}
	return out
}

// skipping reports whether a token in the current position belongs to a dead branch.
fn (p &Preprocessor) skipping() bool {
	return p.enclosing_dead()
}

// enclosing_dead reports whether any open conditional level is not live. It is
// `skipping` under a name that says what it means, because the two are used at
// different points: `skipping` while reading tokens, `enclosing_dead` while deciding
// a branch's fate, where the innermost level must be excluded.
fn (p &Preprocessor) enclosing_dead() bool {
	for c in p.cond_stack {
		if !c.live {
			return true
		}
	}
	return false
}

// --- phase 1: directives, conditionals, includes ---

// directives handles every `#` line: it defines macros, evaluates conditionals, and
// splices in included files. Dead branches are discarded here so that phase 2 never
// sees a token from one.
//
// **Expansion is interleaved with the directives, not deferred.** The tokens in front
// of a directive are expanded at the point that directive is reached, with the macro
// table as it stands there. Running one expansion pass over the whole stream instead —
// which is what this did — makes every `#define` in the file take effect *retroactively*:
//
//	#define M14(...) 3
//	int a = M14();                             // 3, correctly
//	#define M14(x, ...) add6(1,2,x,__VA_ARGS__,6)
//	int c = M14(3,4,5);                        // add6(1,2,3,4,5,6), correctly
//
// expanded the first `M14()` with the *second* definition, reported
// `macro M14 requires 1 arguments, but 0 given` against the first line, and left it
// unexpanded. Measured on chibicc's macro.c line 347. [C11 6.10p7] is explicit that a
// preprocessing directive takes effect from the point it appears, and the same defect
// is why a retroactive `#define` from a header can reject a perfectly ordinary call
// elsewhere in the file.
//
// The `pending` batch is flushed on every directive and once more at the end, because a
// batch is delimited by a directive on either side: an invocation never spans one.
fn (mut p Preprocessor) directives(toks []ast.Token, path string) []ast.Token {
	mut out := []ast.Token{}
	mut pending := []ast.Token{}
	mut i := 0
	for i < toks.len {
		tok := toks[i]
		if tok.kind != .preproc_any {
			if !p.skipping() {
				pending << tok
			}
			i++
			continue
		}
		if pending.len > 0 {
			out << p.expand(pending, path)
			pending = []ast.Token{}
		}
		// Split the directive into its name and its argument text. The tokenizer hands
		// over the whole line, so the name is the first identifier-like run.
		body := directive_body(tok.text)
		name := directive_name(body)
		rest := directive_rest(body, name)
		line := tok.line.disp_line
		i++

		// Conditionals are tracked even inside a dead branch, so that a nested `#if`
		// in skipped code cannot unbalance the level of an outer `#else`.
		match name {
			'if' {
				// The enclosing state must be sampled before this level is pushed,
				// because `skipping` looks at the whole stack.
				mut live := false
				if !p.skipping() {
					live = p.eval_condition(rest, path, line)
				}
				p.cond_stack << Conditional{
					taken: live
					live:  live
					line:  line
				}
			}
			'ifdef', 'ifndef' {
				mut live := false
				if !p.skipping() {
					live = p.eval_ifdef(name, rest, line)
				}
				p.cond_stack << Conditional{
					taken: live
					live:  live
					line:  line
				}
			}
			'elif' {
				if p.cond_stack.len == 0 {
					p.errorf(line, '#elif without #if')
				} else {
					mut c := p.cond_stack[p.cond_stack.len - 1]
					if c.in_else {
						p.errorf(line, '#elif after #else')
					}
					mut live := false
					if c.live {
						// A previous branch of this level was already emitted, so this
						// one is dead regardless of its condition.
						live = false
					} else if c.taken || p.outer_dead() {
						live = false
					} else {
						live = p.eval_condition(rest, path, line)
					}
					c.live = live
					if live {
						c.taken = true
					}
					p.cond_stack[p.cond_stack.len - 1] = c
				}
			}
			'else' {
				if p.cond_stack.len == 0 {
					p.errorf(line, '#else without #if')
				} else {
					mut c := p.cond_stack[p.cond_stack.len - 1]
					if c.in_else {
						p.errorf(line, '#else after #else')
					}
					c.in_else = true
					// The else branch is live exactly when no earlier branch was
					// selected, and it is only reachable at all when the enclosing
					// levels are live.
					c.live = !c.taken && !p.outer_dead()
					c.taken = true
					p.cond_stack[p.cond_stack.len - 1] = c
				}
			}
			'endif' {
				if p.cond_stack.len == 0 {
					p.errorf(line, '#endif without #if')
				} else {
					p.cond_stack.delete(p.cond_stack.len - 1)
				}
			}
			else {
				if p.skipping() {
					continue
				}
				p.simple_directive(name, rest, line, path, mut out)
			}
		}
	}
	// The last batch has no directive after it, so nothing has flushed it yet.
	if pending.len > 0 {
		out << p.expand(pending, path)
	}
	return out
}

// directive_body strips the leading `#` and any spaces after it.
fn directive_body(text string) string {
	mut s := text.trim_space()
	if s.starts_with('#') {
		s = s[1..]
	}
	return s.trim_space()
}

// directive_name returns the directive keyword, which is the leading run of
// identifier characters.
fn directive_name(body string) string {
	mut i := 0
	for i < body.len && (body[i] == `_` || (body[i] >= `a` && body[i] <= `z`)
		|| (body[i] >= `A` && body[i] <= `Z`) || (body[i] >= `0` && body[i] <= `9`)) {
		i++
	}
	return body[..i]
}

// directive_rest is everything after the directive keyword, with leading spaces
// removed.
fn directive_rest(body string, name string) string {
	if name.len == 0 || name.len >= body.len {
		return ''
	}
	return body[name.len..].trim_space()
}

// outer_dead reports whether any level *outside* the innermost one is not live.
//
// It is what a branch's fate depends on, and the innermost level must be excluded:
// deciding the liveness of `#else` for `#if 0` under a live outer would consult the
// `#if 0` level itself and wrongly conclude the `#else` is dead.
fn (p &Preprocessor) outer_dead() bool {
	if p.cond_stack.len == 0 {
		return false
	}
	for i in 0 .. p.cond_stack.len - 1 {
		if !p.cond_stack[i].live {
			return true
		}
	}
	return false
}

// simple_directive handles the directives that are neither conditionals nor includes.
fn (mut p Preprocessor) simple_directive(name string, rest string, line int, path string,
	mut out []ast.Token) {
	match name {
		'define' {
			p.do_define(rest, line)
		}
		'undef' {
			if rest.len > 0 {
				p.undef_macro_name(rest)
			} else {
				p.errorf(line, '#undef without a macro name')
			}
		}
		'include', 'include_next' {
			p.do_include(rest, line, path, mut out)
		}
		'error' {
			p.errorf(line, rest)
		}
		'warning' {
			// A warning is deliberately dropped rather than printed: the token stream
			// is the product, and a caller that wants them reads `errors`.
		}
		'pragma' {
			p.do_pragma(rest, line, path)
		}
		'line' {
			// Accepted and ignored. The tokenizer already tracks physical lines, and
			// honouring `#line` only matters for diagnostics.
		}
		'' {
			// A null directive, which the standard requires be accepted.
		}
		else {
			p.errorf(line, 'unknown directive #${name}')
		}
	}
}

// do_define handles `#define`.
//
// The distinction between an object-like and a function-like macro is decided by
// whether a `(` immediately follows the name with no space between, which is why the
// check is on raw text rather than on tokens.
fn (mut p Preprocessor) do_define(rest string, line int) {
	if rest.len == 0 {
		p.errorf(line, '#define without a macro name')
		return
	}
	mut i := 0
	for i < rest.len && is_ident_byte(rest[i]) {
		i++
	}
	name := rest[..i]
	if name.len == 0 {
		p.errorf(line, '#define without a macro name')
		return
	}
	// Function-like only when `(` touches the name.
	if i < rest.len && rest[i] == `(` {
		mut j := i
		mut depth := 0
		for j < rest.len {
			if rest[j] == `(` {
				depth++
			} else if rest[j] == `)` {
				depth--
				if depth == 0 {
					j++
					break
				}
			}
			j++
		}
		if depth != 0 {
			p.errorf(line, 'unterminated parameter list in #define ${name}')
			return
		}
		params_text := rest[i + 1..j - 1]
		body_text := rest[j..].trim_space()
		params, va_name, is_variadic := parse_params(params_text)
		p.define_raw(name, true, params, is_variadic, va_name, tokenize_fragment(body_text))
		return
	}
	body_text := rest[i..].trim_space()
	p.define_raw(name, false, []string{}, false, '', tokenize_fragment(body_text))
}

// undef_macro_name removes a macro named by `#undef`.
fn (mut p Preprocessor) undef_macro_name(rest string) {
	mut i := 0
	for i < rest.len && is_ident_byte(rest[i]) {
		i++
	}
	p.undefine(rest[..i])
}

fn is_ident_byte(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
		|| (c >= `0` && c <= `9`)
}

// parse_params splits a macro parameter list into names, recognising `...` and the
// GNU named-variadic form `args...`.
fn parse_params(text string) ([]string, string, bool) {
	mut params := []string{}
	mut va_name := ''
	mut variadic := false
	for raw in text.split(',') {
		piece := raw.trim_space()
		if piece.len == 0 {
			continue
		}
		if piece == '...' {
			variadic = true
			continue
		}
		if piece.ends_with('...') {
			// GNU `, ## __VA_ARGS__` extension: `args...` names the variadic part.
			// The name is deliberately *not* added to params, because it stands for all
			// the remaining arguments rather than for exactly one; adding it would make
			// `param_index` match first and substitute only the first extra argument.
			variadic = true
			va_name = piece[..piece.len - 3].trim_space()
			continue
		}
		params << piece
	}
	return params, va_name, variadic
}

// do_pragma handles `#pragma`. Only `once` has an effect here; the rest are kept out
// of the token stream because the parser has no use for them.
// PackEvent records that `#pragma pack` changed the maximum member alignment at one
// line.
//
// The preprocessor sees the pragma and the layout code needs it, and the two are not
// in the same place: preprocessing produces one token list, and the parser walks it
// without knowing anything about pragmas. Recording where each pragma took effect and
// asking by line number is enough, because a pragma is always on an earlier line than
// the struct definition it governs.
pub struct PackEvent {
pub mut:
	line int
	// pack is the alignment in force from this line on. 0 means none is in force.
	pack int
}

fn (mut p Preprocessor) do_pragma(rest string, line int, path string) {
	if rest == 'once' {
		p.pragma_once[path] = true
		return
	}
	p.do_pragma_pack(rest.trim_space(), line)
}

// do_pragma_pack records a `#pragma pack` directive.
//
// The argument is a parenthesised form: `pack(2)`, `pack(push, 4)`, `pack(push)` or
// `pack(pop)`. The parentheses are stripped first, because the words being looked for
// are inside them — reading `push` off the front of `(push, 4)` finds nothing, and a
// pragma that silently does nothing is worse than one that is rejected.
fn (mut p Preprocessor) do_pragma_pack(body string, line int) {
	if !body.starts_with('pack') {
		return
	}
	rest := strip_outer_parens(body[4..].trim_space())
	if rest == '' {
		return
	}
	if rest == 'pop' {
		if p.pack_stack.len > 0 {
			p.pack_stack.delete(p.pack_stack.len - 1)
		}
	} else if rest.starts_with('push') {
		mut arg := rest[4..].trim_space()
		if arg.starts_with(',') {
			arg = arg[1..].trim_space()
		}
		// `push` with no argument keeps the alignment in force.
		p.pack_stack << if arg == '' { p.pack_value() } else { arg.int() }
	} else {
		p.pack_stack.clear()
		p.pack_stack << rest.int()
	}
	p.packs << PackEvent{
		line: line
		pack: p.pack_value()
	}
}

// strip_outer_parens removes one layer of parentheses if it is there.
fn strip_outer_parens(s string) string {
	if s.len >= 2 && s[0] == `(` && s[s.len - 1] == `)` {
		return s[1..s.len - 1].trim_space()
	}
	return s
}

// pack_value returns the alignment currently in force, or 0 for none.
fn (p &Preprocessor) pack_value() int {
	if p.pack_stack.len == 0 {
		return 0
	}
	return p.pack_stack[p.pack_stack.len - 1]
}

// pack_before returns the alignment in force just before a line.
pub fn (p &Preprocessor) pack_before(line int) int {
	mut pack := 0
	for e in p.packs {
		if e.line < line {
			pack = e.pack
		} else {
			break
		}
	}
	return pack
}

// find_from returns the index of the first `ch` at or after `start`, or none.
//
// The include scanner needs a byte search rather than a string search because the
// delimiters are quote and bracket characters, which are awkward to express as
// string literals in a language where a backtick literal is a `rune`.
fn find_from(s string, start int, ch u8) ?int {
	mut i := start
	for i < s.len {
		if s[i] == ch {
			return i
		}
		i++
	}
	return none
}

// include_spelling renders a macro expansion back into the header name it stands for.
//
// This is the *whole* expansion, not its first token, and that is the defect it fixes.
// `#define M13 < include4.h` followed by `#include M13 >` expands to five tokens — `<`,
// `include4`, `.`, `h`, `>` — so reading only the first left the closing `>` behind in
// tokens that were then dropped, and reported `unterminated include` for a header that
// was spelled correctly. Measured on chibicc's macro.c line 333, the last preprocessor
// defect the suite has to offer.
//
// The tokens are joined with nothing between them rather than with a space, because a
// header name has no whitespace in it: `< include4 . h >` names `include4.h`.
fn include_spelling(toks []ast.Token) string {
	mut s := ''
	for t in toks {
		s += t.text
	}
	return s
}

// do_include resolves an `#include` and splices the included tokens into the output.
fn (mut p Preprocessor) do_include(rest string, line int, path string, mut out []ast.Token) {
	if rest.len == 0 {
		p.errorf(line, '#include expects "FILENAME" or <FILENAME>')
		return
	}
	mut name := ''
	mut angled := false
	if rest[0] == `"` {
		end := find_from(rest, 1, `"`) or {
			p.errorf(line, 'unterminated include')
			return
		}
		name = rest[1..end]
	} else if rest[0] == `<` {
		end := find_from(rest, 1, `>`) or {
			p.errorf(line, 'unterminated include')
			return
		}
		name = rest[1..end]
		angled = true
	} else {
		// A macro may expand to the header name. The standard requires this, and glibc
		// headers rely on it, so it is supported rather than diagnosed.
		//
		// The spelling is read from the whole expansion, not from its first token — see
		// `include_spelling` for the measured case this was written for.
		spelled := include_spelling(strip_sentinels(p.expand(tokenize(rest), path)))
		if spelled.len > 0 && (spelled[0] == `"` || spelled[0] == `<`) {
			closer := if spelled[0] == `"` { `"` } else { `>` }
			end := find_from(spelled, 1, closer) or {
				p.errorf(line, 'unterminated include')
				return
			}
			name = spelled[1..end]
			angled = closer == `>`
		} else {
			p.errorf(line, '#include expects "FILENAME" or <FILENAME>')
			return
		}
	}
	full := p.resolve_include(name, angled, path) or {
		p.errorf(line, 'cannot find include ${name}')
		return
	}
	if p.pragma_once[full] {
		return
	}
	if p.depth >= max_depth {
		p.errorf(line, 'include nested too deeply at ${name}')
		return
	}
	src := os.read_file(full) or {
		p.errorf(line, 'cannot read ${full}')
		return
	}
	p.depth++
	// The included file's directives run with the same macro table and its own
	// conditional stack, so an unbalanced `#if` inside a header cannot swallow the
	// rest of the includer.
	saved_cond := p.cond_stack.clone()
	p.cond_stack = []
	included := p.directives(tokenize(src), full)
	for c in p.cond_stack {
		p.errorf(c.line, 'unterminated #if in ${full}')
		break
	}
	p.cond_stack = saved_cond
	p.depth--
	out << strip_sentinels(included)
}

// strip_sentinels removes the end-of-file tokens an included file brought with it.
//
// `tokenize` ends every file it reads with an `.eof` sentinel, and the parser treats
// the first `.eof` it meets as the end of the translation unit. Splicing a header's
// tokens in therefore used to end the parse at the end of the *first include*: every
// declaration after it was dropped, silently, with no diagnostic.
//
// The invariant is one sentinel, at the very end, and `finish` is what adds it.
fn strip_sentinels(toks []ast.Token) []ast.Token {
	mut out := []ast.Token{cap: toks.len}
	for t in toks {
		if t.kind == .eof {
			continue
		}
		out << t
	}
	return out
}
// resolve_include searches for a header.
//
// A quoted include searches the including file's directory first, which is what
// `#include "sibling.h"` in a header means; an angled include does not, because
// `<...>` names a system header.
fn (p &Preprocessor) resolve_include(name string, angled bool, including string) ?string {
	if !angled {
		dir := os.dir(including)
		candidate := if dir.len > 0 { os.join_path(dir, name) } else { name }
		if os.is_file(candidate) {
			return os.real_path(candidate)
		}
	}
	for dir in p.quote_paths {
		candidate := os.join_path(dir, name)
		if os.is_file(candidate) {
			return os.real_path(candidate)
		}
	}
	for dir in p.angle_paths {
		candidate := os.join_path(dir, name)
		if os.is_file(candidate) {
			return os.real_path(candidate)
		}
	}
	return none
}
