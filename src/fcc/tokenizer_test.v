module fcc
import ast

// Tokenizer tests.
//
// Every case here corresponds to a bug found by running the tokenizer on real C
// rather than by reading it. The numeric and keyword cases in particular encode
// three silent misdecodings that each produced a clean build and a wrong value.

// kinds returns the tokens of `src`, excluding the terminating eof.
fn kinds(src string) []ast.Token {
	mut out := []ast.Token{}
	for t in tokenize(src) {
		if t.kind == .eof {
			continue
		}
		out << t
	}
	return out
}

// The tests compare `text` sequences rather than whole token structs, because a
// struct comparison would also pin down line and column offsets that are not what
// these tests are about.
fn texts(src string) []string {
	return kinds(src).map(it.text)
}

fn only(src string) string {
	t := texts(src)
	assert t.len == 1, 'expected exactly one token, got ${t}'
	return t[0]
}

fn val(src string) i64 {
	for t in tokenize(src) {
		if t.kind == .num_ {
			return t.val
		}
	}
	return 0
}

fn fval(src string) f64 {
	for t in tokenize(src) {
		if t.kind == .num_ {
			return t.fval
		}
	}
	return 0.0
}

fn strdata(src string) string {
	for t in tokenize(src) {
		if t.kind == .str_ {
			return t.str_data.bytestr()
		}
	}
	return ''
}

fn is_keyword_token(src string) bool {
	for t in tokenize(src) {
		if t.kind != .eof {
			return t.kind == .keyword
		}
	}
	return false
}

// --- basics ---

fn test_empty_input_is_only_eof() {
	toks := tokenize('')
	assert toks.len == 1
	assert toks[0].kind == .eof
}

fn test_identifier_and_punctuators() {
	assert texts('int x = 1;') == ['int', 'x', '=', '1', ';']
}

fn test_longest_match_wins_for_multi_character_operators() {
	// A greedy single-character match would produce `<<` `=` instead of `<<=`.
	assert texts('a <<= b') == ['a', '<<=', 'b']
	assert texts('a >>= b') == ['a', '>>=', 'b']
	assert texts('a ... b') == ['a', '...', 'b']
	assert texts('a -> b') == ['a', '->', 'b']
}

fn test_shift_and_shift_assign_are_distinct() {
	assert texts('a << b') == ['a', '<<', 'b']
	assert texts('a <<= b') == ['a', '<<=', 'b']
}

fn test_comments_are_skipped_but_set_has_space() {
	assert texts('a /* x */ b') == ['a', 'b']
	assert texts('a // x
b') == ['a', 'b']
	for t in tokenize('/* x */ b') {
		if t.text == 'b' {
			assert t.has_space
		}
	}
}

fn test_line_comment_ends_at_newline() {
	assert texts('a // b
c') == ['a', 'c']
}

fn test_at_bol_marks_first_token_of_each_line() {
	toks := kinds('a
b')
	assert toks[0].text == 'a'
	assert toks[1].text == 'b'
}

// --- line splicing ---

fn test_backslash_newline_joins_lines() {
	// A splice is not a token boundary, so `in\` + newline + `t` is one identifier.
	assert texts('in\
t') == ['int']
}

fn test_line_splice_inside_a_string_literal() {
	assert strdata('"a\
b"') == 'ab'
}

fn test_line_counter_advances_past_a_splice() {
	// The physical line must still advance, or every diagnostic after a splice is
	// reported on the wrong line.
	for t in tokenize('a\\\nb\nc') {
		if t.text == 'c' {
			assert t.line.disp_line == 3, 'expected line 3, got ${t.line.disp_line}'
		}
	}
}

// --- numbers: the three bugs ---

fn test_hex_integer_value() {
	// A base-blind suffix strip once turned `0x1F` into `0x1`, because `F` is both
	// a hex digit and a float suffix. The literal must be 31.
	assert val('0x1F') == 31
}

fn test_hex_integer_with_suffixes() {
	assert val('0x1Ful') == 31
	assert val('0x1FULL') == 31
	assert val('0x1f') == 31
}

fn test_hex_integer_is_not_stripped_by_the_f_suffix_rule() {
	// `0xF` must be 15, not 0 with a stray suffix.
	assert val('0xF') == 15
	assert val('0xf') == 15
}

fn test_octal_and_decimal() {
	assert val('010') == 8
	assert val('10') == 10
	assert val('0') == 0
}

fn test_binary_extension() {
	assert val('0b1010') == 10
	assert val('0B11') == 3
	// The digit set is binary, not hex. Every binary digit is also a hex digit, which is
	// the only reason a single prefix-blind rule got the value right — and why a wider
	// pp-number scan has to know `0b` is a prefix. See `invalid_numeric_suffix`.
	assert texts('0b1010') == ['0b1010']
	assert texts('0b0L') == ['0b0L']
	assert texts('0b1111') == ['0b1111']
	assert texts('0B101111') == ['0B101111']
}

// [C11 6.4.8] A pp-number continues with identifier-nondigits, so `0zz` is one token.
//
// It used to stop at the first character that was not a suffix letter and split into `0`
// and `zz`, which is what made `CONCAT(f,0zz)` produce `f0` plus `zz` instead of `f0zz`.
fn test_a_pp_number_is_one_token() {
	assert texts('0zz') == ['0zz']
	assert texts('1abc') == ['1abc']
	assert texts('3.5foo') == ['3.5foo']
	assert texts('0x1z') == ['0x1z']
	assert texts('1e5x') == ['1e5x']
	assert texts('1p+3') == ['1p+3']
	assert texts('1$') == ['1$']
	// The sign rule is tested before the identifier rule, because `p` is an identifier
	// character: `1p+3` must be one pp-number and not `1p` followed by `+3`.
	assert texts('0b11 + 2') == ['0b11', '+', '2']
}

// A pp-number that is not a valid constant is a diagnostic, not a value.
//
// The token-level guard (`invalid_numeric_suffix`) is pinned in `parser_test.v`, which is
// the only unit that has the parser in scope to see the diagnostic. The token shapes
// above are this file's half.
fn test_an_invalid_pp_number_is_one_token() {
	assert texts('0zz') == ['0zz']
	assert texts('1abc') == ['1abc']
}


fn test_decimal_float() {
	assert fval('1.5') == 1.5
	assert fval('1.5e3') == 1500.0
	assert fval('1.5e3f') == 1500.0
	assert fval('.5') == 0.5
	assert fval('1.') == 1.0
}

fn test_hex_float_is_one_token() {
	// It used to be split into `0x1`, `.8` and `p3` because the `.` was not
	// consumed in the hexadecimal branch.
	assert texts('0x1.8p3') == ['0x1.8p3']
	assert fval('0x1.8p3') == 12.0
	assert fval('0x1.8p1') == 3.0
	assert fval('0xA.8p0') == 10.5
	assert fval('0x0.8p1') == 1.0
	assert fval('0x1p4') == 16.0
}

fn test_leading_dot_float_is_not_member_access() {
	// `.5` is a float; `a.b` is a member access.
	assert texts('a.b') == ['a', '.', 'b']
	assert texts('.5') == ['.5']
}

// --- characters and strings ---

fn test_character_constant() {
	assert val("'A'") == 65
	// A V double-quoted string is used for the C source rather than a backtick one:
	// this V build treats a multi-character backtick literal as an error, and
	// `"'\\n'"` is exactly the four characters `'`, `\`, `n`, `'`.
	assert val("'\\n'") == 10
	assert val("'\\0'") == 0
}

fn test_character_escape_forms() {
	assert val("'\\x41'") == 65
	assert val("'\\101'") == 65 // octal
	assert val("'\\t'") == 9
	assert val("'\\\\'") == 92
	assert val("'\\''") == 39
}

fn test_multicharacter_constant_takes_the_last_character() {
	// GCC and tcc both reduce this the same way.
	assert val("'ab'") == i64(`b`)
}

fn test_string_literal_decodes_escapes() {
	assert strdata('"a\\tb"') == 'a\tb'
	assert strdata('"a\\\\b"') == 'a\\b'
	assert strdata('"\\x41\\x42"') == 'AB'
}

fn test_string_literal_keeps_its_quotes_in_text() {
	assert only('"hi"') == '"hi"'
}

fn test_wide_and_utf_literals() {
	// A regression test for an ordering bug: the wide-literal check ran after the
	// identifier check, so `L"x"` lexed as the identifier `L` followed by `"x"`.
	assert texts('L"x"') == ['L"x"']
	assert texts("u8'x'") == ["u8'x'"]
	assert texts('U"x"') == ['U"x"']
	assert texts('u"x"') == ['u"x"']
}

fn test_u_prefixed_identifiers_are_not_wide_literals() {
	// `u` begins ordinary identifiers; only a quote or `8` makes it a literal.
	assert texts('unsigned x') == ['unsigned', 'x']
	assert texts('uint8_t x') == ['uint8_t', 'x']
	assert texts('u8int x') == ['u8int', 'x']
}

fn test_unterminated_string_does_not_hang() {
	// It must terminate at the line end rather than consuming the file.
	t := texts('"abc
def')
	assert t.len == 2
	assert t[0] == '"abc'
}

// --- keywords ---

fn test_c_keywords_are_keywords() {
	for k in ['int', 'char', 'if', 'else', 'while', 'for', 'return', 'switch', 'case', 'default',
		'do', 'break', 'continue', 'goto', 'struct', 'union', 'enum', 'typedef', 'static', 'extern',
		'const', 'volatile', 'inline', 'sizeof', 'void', 'unsigned', 'signed', 'short', 'long',
		'float', 'double', 'register', 'restrict'] {
		assert is_keyword_token(k), 'expected ${k} to be a keyword'
	}
}

fn test_c11_keywords_are_keywords() {
	for k in ['_Alignas', '_Alignof', '_Atomic', '_Bool', '_Generic', '_Noreturn', '_Static_assert',
		'_Thread_local'] {
		assert is_keyword_token(k), 'expected ${k} to be a keyword'
	}
}

fn test_gnu_keywords_are_keywords() {
	// These are the constructs V's generated C relies on. See docs/CONTRACT.md.
	for k in ['__attribute__', 'typeof', '__asm__', '__extension__', '__restrict__', '__builtin_va_arg',
		'__builtin_offsetof', '__builtin_types_compatible_p', '__builtin_constant_p'] {
		assert is_keyword_token(k), 'expected ${k} to be a keyword'
	}
}

fn test_gnu_alias_spellings_fold_onto_one_keyword() {
	// `__inline__` and `inline` must be the same keyword, or the parser has to
	// accept both everywhere.
	assert is_keyword_token('__inline')
	assert is_keyword_token('__inline__')
	assert is_keyword_token('__const')
	assert is_keyword_token('__typeof__')
	assert is_keyword_token('__attribute')
}

fn test_identifiers_that_merely_resemble_keywords() {
	for k in ['integer', 'iffy', 'return_value', '_static', 'struct_', 'for_each'] {
		assert !is_keyword_token(k), 'expected ${k} to be an identifier'
	}
}

fn test_keyword_name_round_trips() {
	// The `match`-based keyword table replaced a `const map[Keyword]string` that
	// this V build compiled into a 43-entry map whose values were misaligned with
	// their keys: indexing it with `.case_` returned `.while_`'s spelling. Nothing
	// errored, so only a value-level assertion catches that class of defect.
	//
	// Each pair is asserted in both directions, which is what a shifted table
	// fails.
	pairs := {
		'int':           ast.Keyword.int_
		'case':          ast.Keyword.case_
		'do':            ast.Keyword.do_
		'for':           ast.Keyword.for_
		'if':            ast.Keyword.if_
		'return':        ast.Keyword.return_
		'switch':        ast.Keyword.switch_
		'while':         ast.Keyword.while_
		'goto':          ast.Keyword.goto_
		'void':          ast.Keyword.void_
		'union':         ast.Keyword.union_
		'typedef':       ast.Keyword.typedef_
		'volatile':      ast.Keyword.volatile_
		'typeof':        ast.Keyword.typeof
		'_Generic':      ast.Keyword.generic
		'__attribute__': ast.Keyword.attribute
	}
	assert pairs.len == 16
	for spelling, k in pairs {
		assert ast.keyword_name(k) == spelling, 'keyword_name mismatch for ${spelling}'
		if got := ast.keyword_from_spelling(spelling) {
			assert got == k, 'spelling mismatch for ${spelling}'
		} else {
			assert false, '${spelling} did not resolve'
		}
	}
}

fn test_every_keyword_has_a_distinct_spelling() {
	// A table that shifted would also produce duplicates. Comparing the count of
	// distinct names against the number of keywords catches that directly.
	names := [
		'auto',
		'break',
		'case',
		'char',
		'const',
		'continue',
		'default',
		'do',
		'double',
		'else',
		'enum',
		'extern',
		'float',
		'for',
		'goto',
		'if',
		'inline',
		'int',
		'long',
		'register',
		'return',
		'short',
		'signed',
		'sizeof',
		'static',
		'struct',
		'switch',
		'typedef',
		'union',
		'unsigned',
		'void',
		'volatile',
		'while',
		'_Alignas',
		'_Alignof',
		'_Atomic',
		'_Bool',
		'_Generic',
		'_Noreturn',
		'_Static_assert',
		'_Thread_local',
		'__attribute__',
		'typeof',
		'__asm__',
		'__extension__',
		'__restrict__',
		'__builtin_va_arg',
		'__builtin_offsetof',
		'__builtin_types_compatible_p',
		'__builtin_constant_p',
	]
	mut seen := map[string]bool{}
	for n in names {
		assert n !in seen, 'duplicate keyword spelling ${n}'
		seen[n] = true
	}
	// Every one of these must resolve, or the two tables have drifted apart.
	for n in names {
		assert ast.keyword_from_spelling(n) != none, '${n} did not resolve'
	}
}

// --- non-ASCII identifiers ---

fn test_a_non_ascii_identifier_stays_one_token() {
	// Every byte of a multi-byte UTF-8 sequence is 0x80 or above, so classifying those
	// bytes as punctuators split `int π = 3;` into two punctuation tokens and then
	// reported `variable name omitted` on the `=`.
	toks := tokenize('int πx = 3;')
	// The last token is the end-of-file sentinel.
	assert toks.len == 6, 'got ${toks.len} tokens'
	assert toks[1].kind == .ident, 'got ${toks[1].kind}'
	// The spelling is kept as written, so a diagnostic quotes it back unchanged.
	assert toks[1].text == 'πx', 'got ${toks[1].text}'
}

fn test_a_non_ascii_identifier_continues_over_ascii_letters_and_digits() {
	toks := tokenize('int aπ9 = 1;')
	assert toks[1].kind == .ident, 'got ${toks[1].kind}'
	assert toks[1].text == 'aπ9', 'got ${toks[1].text}'
}

fn test_a_non_ascii_byte_continues_an_identifier_too() {
	// The same rule as for the start, so  + U+00D7 +  is one identifier — which is
	// what gcc, tcc and chibicc all make of it.
	toks := tokenize('a×b')
	assert toks.len == 2, 'got ${toks.len} tokens'
	assert toks[0].kind == .ident, 'got ${toks[0].kind}'
	assert toks[0].text == 'a×b', 'got ${toks[0].text}'
}

fn test_a_dollar_sign_belongs_to_an_identifier() {
	// A GCC extension, not C — but tcc and chibicc both accept it and generated C in the
	// wild uses it. Measured against tcc rather than assumed: it compiles and runs.
	toks := tokenize('int $$$ = 5;')
	assert toks[1].kind == .ident, 'got ${toks[1].kind}'
	assert toks[1].text == '$$$', 'got ${toks[1].text}'
}

fn test_a_dollar_sign_continues_an_identifier() {
	toks := tokenize('int a$b = 1;')
	assert toks[1].kind == .ident, 'got ${toks[1].kind}'
	assert toks[1].text == 'a$b', 'got ${toks[1].text}'
}

fn test_a_line_splice_joins_the_two_halves_of_a_keyword() {
	// [C11 5.1.1.2p1.2] deletes the pair before tokenization, so this is `sizeof` and
	// not the two tokens `size` and `of`. `skip_insignificant` already handled a splice
	// *between* tokens; it could not reach one inside one, because it stops at the first
	// byte of the token.
	toks := tokenize('size\\\nof(int);')
	// `sizeof`, `(`, `int`, `)`, `;`, eof.
	assert toks.len == 6, 'got ${toks.len}'
	assert toks[0].kind == .keyword, 'got ${toks[0].kind}'
	assert toks[0].text == 'sizeof', 'got ${toks[0].text}'
	assert toks[0].is_keyword, 'the keyword lookup did not see the joined spelling'
}

fn test_a_line_splice_joins_the_two_halves_of_a_number() {
	// A literal split in two changes a program's arithmetic rather than naming
	// anything, so this is the case that cannot be left until someone notices a wrong
	// answer: one constant, not two.
	toks := tokenize('int a = 1\\\n23;')
	assert toks.len == 6, 'got ${toks.len}'
	assert toks[3].kind == .num_, 'got ${toks[3].kind}'
	assert toks[3].val == 123, 'got ${toks[3].val}'
	// And a hexadecimal one, which is where the scanner's two branches differ.
	hex := tokenize('int a = 0x1\\\nF + 1;')
	assert hex.len == 8, 'got ${hex.len}'
	assert hex[3].text == '0x1F', 'got ${hex[3].text}'
	assert hex[3].val == 31, 'got ${hex[3].val}'
}

fn test_a_line_splice_does_not_end_a_quoted_literal() {
	// The literal's terminating newline is the *second* byte of the pair, so the splice
	// has to be tested before it. Read the other way round, `"spli\` + `ced"` is a
	// one-token string literal followed by three stray identifiers.
	toks := tokenize('char *s = "spli\\\nced";')
	// `char`, `*`, `s`, `=`, the literal, `;`, eof.
	assert toks.len == 7, 'got ${toks.len}'
	assert toks[4].kind == .str_, 'got ${toks[4].kind}'
	assert toks[4].str_data == 'spliced'.bytes(), 'got ${toks[4].str_data.bytestr()}'
	// The closing quote was still found, so the literal did not run to end of file: the
	// `;` after it is a token rather than part of the string.
	assert toks[5].text == ';', 'got ${toks[5].text}'
}

fn test_the_simple_escapes_decode_to_their_values() {
	// All eight, from the one reproducer that found them: `\a`, `\b`, `\v`, `\f` and `\e`
	// were served by a lookup table that never matched, so every one of them decoded as
	// the letter itself — `\a` came out as 97. The five that had explicit arms were fine.
	// The five that were broken, plus `\t`, which is the one non-breaking escape the old
	// `match` also served. `\n` and `\r` are left out on purpose: interpolating them puts a
	// real line break inside the literal, and a string literal ends at one — so this would
	// be testing the file I wrote rather than the escape.
	for c in [`\a`, `\b`, `\v`, `\f`, `\e`, `\t`] {
		// `char` `*` `p` `=` the-literal `;` and the eof sentinel.
		toks := tokenize('char *p = "x${c}y";')
		assert toks.len == 7, 'got ${toks.len} tokens for ${c}'
		body := toks[4].str_data
		// Three bytes, not four: `x`, the escape, `y`. The terminating NUL is added later,
		// when the literal's array type is built, so it is not in the token's own data.
		assert body.len == 3, '${c} decoded to ${body.len} bytes'
		assert body[0] == `x`, 'got ${body[0]}'
		assert body[2] == `y`, 'got ${body[2]}'
		assert body[1] == u8(simple_escape_value(c)), '${c} gave ${body[1]}'
	}
}

// simple_escape_value is what C11 5.2.2 specifies, spelled independently of the tokenizer
// so that this test is not checking the tokenizer against itself.
fn simple_escape_value(c u8) int {
	return match c {
		`\a` { 7 }
		`\b` { 8 }
		`\v` { 11 }
		`\f` { 12 }
		`\e` { 27 }
		`\t` { 9 }
		`\n` { 10 }
		`\r` { 13 }
		else { -1 }
	}
}
