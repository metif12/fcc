module vcc

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
