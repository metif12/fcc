module vcc

import strconv
import ast

// The tokenizer.
//
// This is the lowest layer of the front end and the one place where C's lexical
// rules have to be got exactly right, because every error above it is reported
// through a position produced here. Two rules drive the design:
//
//   - Line splicing happens *before* tokenization, because C says a
//     backslash-newline is not a token boundary. Doing it as a later pass would
//     mean every token could contain a splice.
//   - The preprocessor needs a token stream rather than characters, so a `#`
//     line is surfaced as one `preproc_any` token. Resplitting it later would be
//     far more work than handing the preprocessor a line of text.
//
// Diagnostics never stop tokenization. A malformed literal becomes a token that
// records the problem, so one bad header does not hide the rest of the file.
//
// Note on character literals: in the V build this project targets, both `'x'` and
// `` `x` `` denote a `u8`, so they are interchangeable here and the backtick form
// is used throughout for consistency with the source's own punctuation.

// hash_byte is `#`. It is a named constant rather than a literal because a `u8`
// array element written as a character gets mangled by the formatter, and because
// `str` on a `u8` yields its decimal value rather than the character, so the two
// mistakes look deceptively similar.
const hash_byte = u8(35)

pub struct Tokenizer {
pub mut:
	// src is the whole file text. Tokenizing indexes into it rather than copying
	// substrings, which keeps memory flat for the large generated C that V
	// produces.
	src string
	// pos is the current byte offset into src.
	pos int
	// line is the 1-based physical line, tracked alongside pos so a diagnostic does
	// not have to recount.
	line int
	// line_start is the offset at which the current line began.
	line_start int
	// at_bol marks that the next token is the first on its line.
	at_bol bool
	// has_space marks that whitespace preceded the token, which `#` stringizing
	// needs in order to reproduce the original spacing.
	has_space bool
}

// punctuators is ordered longest-first so that a greedy match yields `<<=` rather
// than `<<` followed by `=`.
//
// The list is C11 plus the GNU forms V's generated C can contain. Three-character
// sequences appear before two-character ones for the same reason: the scan takes
// the first match, so a shorter entry placed earlier would win.
//
// `...` is written as three dots rather than an ellipsis character so the source
// stays pure ASCII.
pub const punctuators = [
	'<<=',
	'>>=',
	'...'
	'->',
	'++',
	'--',
	'<<',
	'>>',
	'<=',
	'>=',
	'==',
	'!=',
	'&&',
	'||',
	'+=',
	'-=',
	'*=',
	'/=',
	'%=',
	'&=',
	'|=',
	'^=',
	'##',
	'::'
	// single characters, checked last
	'+',
	'-',
	'*',
	'/',
	'%',
	'&',
	'|',
	'^',
	'!',
	'~',
	'=',
	'<',
	'>',
	'?',
	':',
	';',
	',',
	'.',
	'(',
	')',
	'[',
	']',
	'{',
	'}',
	'#',
]

// simple_escapes maps a C escape letter to the value it produces. Kept as data so
// the preprocessor can share it when decoding `#` stringized output.
pub const simple_escapes = {
	'a': 7
	'b': 8
	't': 9
	'n': 10
	'v': 11
	'f': 12
	'r': 13
	'e': 27
}

// tokenize converts src into a token list ending with a single eof token.
//
// The eof token is what lets the parser loop on "is the next token x?" without
// separately testing for end of input at every call site.
//
// The first token is treated as being at the beginning of a line, because that is
// true of a whole file. Use `tokenize_fragment` for a piece of text lifted out of a
// file, such as a macro body.
pub fn tokenize(src string) []ast.Token {
	return tokenize_with(src, true)
}

// tokenize_fragment is `tokenize` for text that is not a whole file: a macro body,
// a directive's argument text, or a `#if` expression.
//
// The difference is decisive rather than cosmetic. In a whole file a `#` at the start
// of a line begins a directive, so `#define S(x) #x` re-tokenized as a body would
// turn `#x` into a directive token and the stringize operator would vanish. A
// fragment's leading `#` is an operator.
pub fn tokenize_fragment(src string) []ast.Token {
	return tokenize_with(src, false)
}

fn tokenize_with(src string, first_at_bol bool) []ast.Token {
	mut t := Tokenizer{
		src:    src
		pos:    0
		line:   1
		at_bol: first_at_bol
	}
	mut out := []ast.Token{}
	for {
		t.skip_insignificant()
		if t.pos >= t.src.len {
			break
		}
		start_bol := t.at_bol
		start_space := t.has_space
		start := t.pos
		mut tok := t.next_token()
		tok.at_bol = start_bol
		tok.has_space = start_space
		tok.loc = ast.Pos(start)
		out << tok
		if t.pos == start {
			// Guarantee forward progress even if a future branch forgets to
			// advance: skip one byte of unknown input rather than spin.
			t.pos++
		}
	}
	out << ast.Token{
		kind:   .eof
		text:   ''
		loc:    ast.Pos(t.src.len)
		line:   ast.Line{
			disp_line: t.line
			disp_col:  1
		}
		at_bol: true
	}
	return out
}

// skip_insignificant consumes whitespace, comments and line splices, updating the
// line counter and the at_bol / has_space flags.
fn (mut t Tokenizer) skip_insignificant() {
	for t.pos < t.src.len {
		c := t.src[t.pos]
		if c == `\\` && t.peek_at(t.pos + 1) == `\n` {
			// A splice removes the newline, so the logical line continues. The
			// physical line still advances, which is why `line` is bumped here.
			t.pos += 2
			t.line++
			t.line_start = t.pos
			continue
		}
		if c == `\n` {
			t.pos++
			t.line++
			t.line_start = t.pos
			t.at_bol = true
			t.has_space = false
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` || c == 0x0b || c == 0x0c {
			t.pos++
			t.has_space = true
			continue
		}
		if c == `/` && t.peek_at(t.pos + 1) == `/` {
			for t.pos < t.src.len && t.src[t.pos] != `\n` {
				t.pos++
			}
			t.has_space = true
			continue
		}
		if c == `/` && t.peek_at(t.pos + 1) == `*` {
			t.pos += 2
			for t.pos < t.src.len {
				if t.src[t.pos] == `\n` {
					t.line++
					t.line_start = t.pos + 1
				}
				if t.src[t.pos] == `*` && t.peek_at(t.pos + 1) == `/` {
					t.pos += 2
					break
				}
				t.pos++
			}
			t.has_space = true
			continue
		}
		break
	}
}

// peek_at returns the byte at offset, or 0 past the end, so lookahead needs no
// bounds check at the call site.
fn (t &Tokenizer) peek_at(offset int) u8 {
	if offset < 0 || offset >= t.src.len {
		return 0
	}
	return t.src[offset]
}

fn (t &Tokenizer) make_line() ast.Line {
	return ast.Line{
		disp_line: t.line
		disp_col:  t.pos - t.line_start + 1
	}
}

fn (mut t Tokenizer) next_token() ast.Token {
	c := t.src[t.pos]
	next := t.peek_at(t.pos + 1)
	// The wide-literal prefixes are checked before identifiers. `L` and `U` are
	// identifier characters, so testing for the identifier first would swallow the
	// prefix and lex `L"x"` as two tokens — the identifier `L` then the string
	// `"x"` — which is silently wrong rather than an error. `u` needs the same
	// care, since it also begins ordinary identifiers such as `unsigned` and
	// `uint8_t`, so only `u8`, `u"` and `u'` qualify.
	if c == `L` && (next == `"` || next == `'` || next == `u` || next == `U`) {
		return t.read_wide_literal()
	}
	if c == `u` && (next == `"` || next == `'` || next == `8`) {
		return t.read_wide_literal()
	}
	if c == `U` && (next == `"` || next == `'`) {
		return t.read_wide_literal()
	}
	if is_ident_start(c) {
		return t.read_ident()
	}
	if is_digit(c) {
		return t.read_number()
	}
	// A `.` followed by a digit is a floating constant, not the member-access
	// punctuator. Checking this before punctuators is what makes `.5` lex
	// correctly.
	if c == `.` && is_digit(next) {
		return t.read_number()
	}
	if c == `"` {
		return t.read_string()
	}
	if c == `'` {
		return t.read_char()
	}
	if c == `#` && t.at_bol {
		return t.read_directive()
	}
	return t.read_punct()
}

fn is_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

// is_ident_start implements C11 Annex D's identifier rule, restricted to ASCII plus
// underscore. A locale-aware `isalpha` would make the lexer's behaviour depend on
// the process environment, which is not acceptable for a compiler.
//
// Every byte of a multi-byte UTF-8 sequence is 0x80 or above, and every compiler accepts
// such an identifier: gcc, clang, tcc and chibicc all take `int π = 3;`, and V's own
// generated C contains such names. Decoding is deliberately not attempted here — what
// matters for the lexer is only that the bytes stay in one token, and the identifier
// keeps whatever spelling the source gave it, so a diagnostic quotes it back unchanged.
//
// The rule is the same for the start of an identifier and for a character continuing one,
// so `a×b` is the single identifier every compiler agrees it is, and
// `is_ident_cont` inherits it from here rather than repeating it.
fn is_ident_start(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c >= 0x80
}

fn is_ident_cont(c u8) bool {
	return is_ident_start(c) || is_digit(c)
}

fn (mut t Tokenizer) read_ident() ast.Token {
	start := t.pos
	for t.pos < t.src.len && is_ident_cont(t.src[t.pos]) {
		t.pos++
	}
	text := t.src[start..t.pos]
	kw := lookup_keyword(text)
	return ast.Token{
		kind:       if kw == none { .ident } else { .keyword }
		text:       text
		is_keyword: kw != none
		len:        t.pos - start
		line:       t.make_line()
	}
}

// lookup_keyword returns the keyword for a spelling, or none for an identifier.
//
// The alternative spellings GCC accepts are folded onto the standard keyword here,
// because generated C may contain either form. Keeping the alias table in one place
// stops `__inline` and `inline` from becoming two different keywords that the
// parser then has to accept everywhere.
fn lookup_keyword(text string) ?ast.Keyword {
	if k := ast.keyword_from_spelling(text) {
		return k
	}
	match text {
		'__inline', '__inline__' { return ast.Keyword.inline_ }
		'__const', '__const__' { return ast.Keyword.const_ }
		'__volatile', '__volatile__' { return ast.Keyword.volatile_ }
		'__signed', '__signed__' { return ast.Keyword.signed_ }
		'__attribute', '__attribute__' { return ast.Keyword.attribute }
		'__asm' { return ast.Keyword.asm_ }
		'__typeof', '__typeof__' { return ast.Keyword.typeof }
		'__alignof', '__alignof__' { return ast.Keyword.alignof }
		'__thread' { return ast.Keyword.thread_local }
		'__auto_type' { return ast.Keyword.auto_ }
		'__builtin_offsetof' { return ast.Keyword.offsetof }
		'__builtin_va_arg' { return ast.Keyword.va_arg }
		'__builtin_types_compatible_p' { return ast.Keyword.types_compatible_p }
		'__builtin_constant_p', '__builtin_bswap16' { return ast.Keyword.constant_p }
		else {
			return none
		}
	}
}

fn (mut t Tokenizer) read_punct() ast.Token {
	for p in punctuators {
		if t.src.len - t.pos >= p.len && t.src[t.pos..t.pos + p.len] == p {
			t.pos += p.len
			return ast.Token{
				kind: .punct
				text: p
				len:  p.len
				line: t.make_line()
			}
		}
	}
	// An unrecognized byte becomes a one-character punctuator so the parser can
	// report it at the right position instead of the tokenizer aborting.
	c := t.src[t.pos]
	t.pos++
	return ast.Token{
		kind: .punct
		text: c.str()
		len:  1
		line: t.make_line()
	}
}

// read_number reads an integer or floating constant and decodes its value.
//
// The value is decoded here rather than in the parser because C allows a suffix and
// a base prefix, and `0x10` must not be confused with `10` at parse time.
fn (mut t Tokenizer) read_number() ast.Token {
	start := t.pos
	mut is_float := false
	if t.src[t.pos] == `0` && (t.peek_at(t.pos + 1) == `x` || t.peek_at(t.pos + 1) == `X`) {
		// A hexadecimal constant is either an integer (`0x1F`) or a float
		// (`0x1.8p3`). The two differ in that the float form carries a `.` and a
		// binary exponent, and both must be consumed here: leaving the `.` behind
		// would split one literal into three tokens.
		t.pos += 2
		for t.pos < t.src.len && is_hex_digit(t.src[t.pos]) {
			t.pos++
		}
		if t.pos < t.src.len && t.src[t.pos] == `.` {
			is_float = true
			t.pos++
			for t.pos < t.src.len && is_hex_digit(t.src[t.pos]) {
				t.pos++
			}
		}
		// A `p` exponent is what actually makes it a float; without one the
		// constant is an integer and `p` would be a separate identifier.
		if t.pos < t.src.len && (t.src[t.pos] == `p` || t.src[t.pos] == `P`) {
			is_float = true
			t.pos++
			if t.pos < t.src.len && (t.src[t.pos] == `+` || t.src[t.pos] == `-`) {
				t.pos++
			}
			for t.pos < t.src.len && is_digit(t.src[t.pos]) {
				t.pos++
			}
		}
	} else {
		for t.pos < t.src.len && is_digit(t.src[t.pos]) {
			t.pos++
		}
		if t.pos < t.src.len && t.src[t.pos] == `.` {
			is_float = true
			t.pos++
			for t.pos < t.src.len && is_digit(t.src[t.pos]) {
				t.pos++
			}
		}
		if t.pos < t.src.len && (t.src[t.pos] == `e` || t.src[t.pos] == `E`) {
			next := t.peek_at(t.pos + 1)
			if is_digit(next) || next == `+` || next == `-` {
				is_float = true
				t.pos += 2
				for t.pos < t.src.len && is_digit(t.src[t.pos]) {
					t.pos++
				}
			}
		}
	}
	// Type suffixes: u/U, l/L, ll/LL, f/F, and combinations. Read greedily and
	// validate in the type checker, because C11 allows several spellings.
	for t.pos < t.src.len && is_suffix_char(t.src[t.pos]) {
		t.pos++
	}
	text := t.src[start..t.pos]
	mut tok := ast.Token{
		kind: .num_
		text: text
		len:  text.len
		line: t.make_line()
	}
	if is_float {
		tok.fval = parse_float(text)
	} else {
		tok.val = parse_integer(text)
	}
	return tok
}

fn is_hex_digit(c u8) bool {
	return is_digit(c) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

// is_suffix_char covers every byte that can follow a numeric literal. Validating
// which suffixes are legal belongs to the type checker; accepting the bytes here
// keeps one place responsible for stopping the scan.
fn is_suffix_char(c u8) bool {
	return is_hex_digit(c) || c == `u` || c == `U` || c == `l` || c == `L` || c == `f`
		|| c == `F`
}

// numeric_min_length is the shortest possible spelling of a literal with the given
// prefix: three characters for `0x` or `0b`, two for a leading-zero octal, and one
// otherwise.
//
// This exists so that stripping a suffix cannot eat the base prefix, which would
// leave nothing to decode.
fn numeric_min_length(s string) int {
	if s.len >= 2 && s[0] == `0` && (s[1] == `x` || s[1] == `X` || s[1] == `b` || s[1] == `B`) {
		return 3
	}
	if s.len >= 1 && s[0] == `0` {
		return 2
	}
	return 1
}

// parse_integer decodes an integer literal, honouring its base prefix.
fn parse_integer(text string) i64 {
	s := strip_numeric_suffix(text)
	mut base := 10
	mut digits := s
	if s.len > 2 && s[0] == `0` && (s[1] == `x` || s[1] == `X`) {
		base = 16
		digits = s[2..]
	} else if s.len > 2 && s[0] == `0` && (s[1] == `b` || s[1] == `B`) {
		// GNU binary constants, which tcc accepts.
		base = 2
		digits = s[2..]
	} else if s.len > 1 && s[0] == `0` {
		base = 8
		digits = s[1..]
	}
	mut v := i64(0)
	for c in digits {
		d := digit_value(c)
		if d < 0 || d >= base {
			continue
		}
		v = v * i64(base) + i64(d)
	}
	return v
}

fn digit_value(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}

// strip_numeric_suffix removes the type suffix from a literal's spelling.
//
// The suffix set depends on the base, and getting this wrong is silent: `f` and
// `F` are float suffixes but they are also hexadecimal digits, so a base-blind
// strip turns `0x1F` into `0x1` and the literal evaluates to 1 instead of 31.
// Only a hexadecimal *float* may carry `f`, and that form always has a `p`
// exponent, which is why `f` is excluded here for hexadecimal.
//
// The length floor stops the strip from eating the base prefix, so `0x` and `0`
// survive.
fn strip_numeric_suffix(s string) string {
	floor_len := numeric_min_length(s)
	// `hex_int` is what makes `0x1F` survive. `f` and `F` are float suffixes but
	// also hexadecimal digits, so they may only be stripped from a literal that is
	// not hexadecimal. A hexadecimal *float* is exempt because it always carries a
	// `p` exponent, and then `f` really is a suffix.
	mut hex_int := s.len >= 2 && s[0] == `0` && (s[1] == `x` || s[1] == `X`)
		&& !s.contains('p')
	mut end := s.len
	for end > floor_len {
		c := s[end - 1]
		if c == `u` || c == `U` || c == `l` || c == `L` {
			end--
			continue
		}
		if !hex_int && (c == `f` || c == `F`) {
			end--
			continue
		}
		break
	}
	return s[..end]
}

// parse_float decodes a floating constant. A form this does not recognise yields
// 0.0, which the type checker reports as a malformed literal rather than silently
// accepting.
fn parse_float(text string) f64 {
	s := strip_numeric_suffix(text)
	if s.len > 1 && s[0] == `0` && (s[1] == `x` || s[1] == `X`) {
		return parse_hex_float(s[2..])
	}
	return strconv.atof64(s) or { 0.0 }
}

// parse_hex_float decodes the `0x1.8p3` form: a hexadecimal mantissa with a binary
// exponent. It appears in V's generated C for float constants.
//
// This must be a single pass over the mantissa. An earlier version had two loops,
// one for the integer part and one for the fraction, and the first did not stop
// scaling at the `.`, so `0x1.8p3` decoded to 192.0 instead of 12.0 without any
// error. The scale is applied only after the point instead.
fn parse_hex_float(s string) f64 {
	mut mantissa := 0.0
	mut scale := 16.0
	mut seen_point := false
	mut i := 0
	for i < s.len && s[i] != `p` && s[i] != `P` {
		if s[i] == `.` {
			// The scale is already 16 for the first fractional digit: `0x1.8` is
			// one plus eight sixteenths. Resetting it to 1 here would make it
			// `0x1.8 == 9`, which is exactly the bug this loop was rewritten to
			// remove.
			seen_point = true
			i++
			continue
		}
		d := digit_value(s[i])
		if d < 0 || d >= 16 {
			break
		}
		if seen_point {
			mantissa += f64(d) / scale
			scale *= 16.0
		} else {
			mantissa = mantissa * 16.0 + f64(d)
		}
		i++
	}
	if i >= s.len {
		return mantissa
	}
	exp := strconv.atoi(s[i + 1..]) or { 0 }
	return mantissa * pow2(exp)
}

fn pow2(exp int) f64 {
	mut result := 1.0
	mut n := exp
	if n < 0 {
		n = -n
		for _ in 0 .. n {
			result /= 2.0
		}
	} else {
		for _ in 0 .. n {
			result *= 2.0
		}
	}
	return result
}

// no_prefix is the sentinel `from` uses to mean "the literal starts here". A
// sentinel of 0 would be wrong: `L"x"` at the very start of a file has its prefix
// at offset 0, and testing `from > 0` silently dropped the `L` from the token's
// text while still decoding the literal correctly.
const no_prefix = -1

fn (mut t Tokenizer) read_string() ast.Token {
	return t.read_quoted(`"`, no_prefix)
}

fn (mut t Tokenizer) read_char() ast.Token {
	return t.read_quoted(`'`, no_prefix)
}

// read_wide_literal handles the L, u, U and u8 prefixed literals.
//
// The prefix is consumed here so the token's `text` is the whole literal, and the
// decoded bytes land in `str_data` for a string or `val` for a character. V emits
// these for rune and array elements, so they cannot be deferred.
fn (mut t Tokenizer) read_wide_literal() ast.Token {
	start := t.pos
	t.pos++ // the L / u / U prefix
	if t.pos < t.src.len && t.src[t.pos] == `8` {
		t.pos++
	}
	if t.pos < t.src.len && t.src[t.pos] == `"` {
		return t.read_quoted(`"`, start)
	}
	if t.pos < t.src.len && t.src[t.pos] == `'` {
		return t.read_quoted(`'`, start)
	}
	// Not a literal after all; the prefix stands alone as an identifier.
	t.pos = start
	return t.read_ident()
}

// read_quoted reads a quoted literal starting at the opening quote, or at `from`
// when a prefix has already been consumed.
//
// A multi-character character constant is reduced by taking the last character,
// which is what GCC and tcc both do. A literal that is never closed stops at the
// line end rather than running to end of file, because the preprocessor must still
// see the tokens after it in order to report anything sensible.
//
// The receiver is mutable because a quoted literal can contain line splices, which
// change the physical line count.
fn (mut t Tokenizer) read_quoted(quote u8, from int) ast.Token {
	start := if from == no_prefix { t.pos } else { from }
	mut i := t.pos + 1
	mut data := []u8{}
	for i < t.src.len && t.src[i] != quote {
		if t.src[i] == `\n` {
			break
		}
		if t.src[i] == `\\` && i + 1 < t.src.len && t.src[i + 1] != `\n` {
			v, next := decode_escape(t.src, i)
			data << v
			i = next
			continue
		}
		data << t.src[i]
		i++
	}
	// Step past the closing quote when there is one.
	mut end := i
	if end < t.src.len && t.src[end] == quote {
		end++
	}
	text := t.src[start..end]
	mut tok := ast.Token{
		kind:     if quote == `"` { .str_ } else { .num_ }
		text:     text
		len:      end - start
		line:     t.make_line()
		str_data: data
	}
	if quote == `'` && data.len > 0 {
		tok.val = i64(data.last())
	}
	for j in start .. end {
		if t.src[j] == `\n` {
			t.line++
		}
	}
	t.pos = end
	t.line_start = end
	return tok
}

// decode_escape decodes the escape starting at `i`, which is the backslash, and
// returns its value and the offset just past it.
//
// Numeric escapes are handled here too, including the variable-length `\x` form
// which consumes as many hex digits as are available. `\0` is handled by the digit
// branch, and an unknown escape yields the character itself per C11 6.4.4.4p9.
fn decode_escape(src string, i int) (u8, int) {
	if i + 1 >= src.len {
		return `\\`, i + 1
	}
	c := src[i + 1]
	if v := simple_escapes[c.str()] {
		return u8(v), i + 2
	}
	match c {
		`n` { return `\n`, i + 2 }
		`t` { return `\t`, i + 2 }
		`r` { return `\r`, i + 2 }
		`\\` { return `\\`, i + 2 }
		`'` { return `'`, i + 2 }
		`"` { return `"`, i + 2 }
		`?` { return `?`, i + 2 }
		else {}
	}
	if c == `x` {
		mut j := i + 2
		mut v := 0
		for j < src.len && is_hex_digit(src[j]) {
			v = v * 16 + digit_value(src[j])
			j++
		}
		return u8(v), j
	}
	if c >= `1` && c <= `7` {
		mut j := i + 1
		mut v := 0
		mut count := 0
		for j < src.len && count < 3 && src[j] >= `0` && src[j] <= `7` {
			v = v * 8 + int(src[j] - `0`)
			j++
			count++
		}
		return u8(v), j
	}
	if is_digit(c) {
		mut j := i + 1
		mut v := 0
		for j < src.len && is_digit(src[j]) {
			v = v * 10 + int(src[j] - `0`)
			j++
		}
		return u8(v), j
	}
	// An unknown escape is the character itself.
	return c, i + 2
}

// read_directive reads a whole `#` line as one token.
//
// The preprocessor needs to see the directive as text — re-tokenizing it after
// macro expansion would be far more work — so the line is captured up to an
// unescaped newline, with splices folded away.
fn (mut t Tokenizer) read_directive() ast.Token {
	mut i := t.pos + 1
	// The captured text has its line splices folded away rather than merely counted.
	// Returning the raw slice would leave `#def\` + newline + `ine` spelling out as
	// `#def\<newline>ine`, and the directive name would come back as `def`, which
	// matches no directive at all.
	//
	// Bytes are accumulated and converted once at the end. Building the string with
	// `u8.str()` looks right but produces `"#100101..."`, because `str` on a `u8` is
	// its decimal value and not the character.
	//
	// The accumulator starts empty and is appended to rather than written as a
	// one-element literal. A current V rejects positional elements in a braced array
	// initializer outright (vlang/v#29217); the toolchain this project was verified
	// against predates that fix and rewrites such a literal into non-compiling code.
	// See notes/DECISIONS.md.
	mut folded := []u8{}
	folded << hash_byte
	for i < t.src.len {
		if t.src[i] == `\n` {
			break
		}
		if t.src[i] == `\\` && i + 1 < t.src.len && t.src[i + 1] == `\n` {
			i += 2
			continue
		}
		if t.src[i] == `\\` && i + 1 < t.src.len && t.src[i + 1] == `\r`
			&& i + 2 < t.src.len && t.src[i + 2] == `\n` {
			i += 3
			continue
		}
		folded << t.src[i]
		i++
	}
	t.pos = i
	t.line_start = i
	text := folded.bytestr()
	return ast.Token{
		kind: .preproc_any
		text: text
		len:  text.len
		line: t.make_line()
	}
}
