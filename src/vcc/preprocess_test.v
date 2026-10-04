module vcc

import os

// Preprocessor tests.
//
// The cases that matter most are the ones that would hang or recurse forever if the
// implementation were wrong: a self-referential macro, a mutually recursive pair, and
// the argument-count and paste paths.

// preprocessed runs source through a fresh preprocessor and returns the token
// spellings joined by spaces, which is the only representation a test should assert
// on — positions and line numbers are not what these tests are about.
fn preprocessed(src string) string {
	return pp(src).text
}

fn pp(src string) PPResult {
	mut p := preprocessor([], [])
	r := p.run_text(src, 'test.c')
	return PPResult{
		text:   r.tokens.filter(it.kind != .eof).map(it.text).join(' ')
		errors: r.errors
	}
}

struct PPResult {
	text   string
	errors []string
}

fn errs(src string) []string {
	return pp(src).errors
}


// --- object-like macros ---

fn test_define_and_expand() {
	assert preprocessed('#define A 1\nA') == '1'
}

fn test_define_without_a_value_is_one() {
	// `-DA` means A is 1, and `#define A` with an empty body is a different thing.
	assert preprocessed('#define A\nA') == ''
	assert preprocessed('#define B\nB') == ''
}

fn test_redefinition_replaces_the_earlier_definition() {
	assert preprocessed('#define A 1\n#define A 2\nA') == '2'
}

fn test_undef_removes_a_macro() {
	assert preprocessed('#define A 1\n#undef A\nA') == 'A'
}

fn test_macro_is_not_expanded_inside_itself() {
	// The recursion guard. Without it this call would not terminate.
	assert preprocessed('#define A A\nA') == 'A'
}

fn test_mutually_recursive_macros_terminate() {
	assert preprocessed('#define A B\n#define B A\nA') == 'A'
}

fn test_three_macro_cycle_terminates() {
	assert preprocessed('#define A B\n#define B C\n#define C A\nA') == 'A'
}

fn test_function_like_macro_does_not_recurse_through_itself() {
	assert preprocessed('#define F(x) F(x)\nF(1)') == 'F ( 1 )'
}

// --- function-like macros ---

fn test_function_like_macro_requires_a_parenthesis() {
	// The distinction that keeps `#define MAX 1` from being invoked by an unrelated
	// bracket. `MAX (x)` leaves the call unexpanded.
	assert preprocessed('#define MAX 1\nMAX') == '1'
}

fn test_function_like_macro_name_without_parenthesis_is_an_identifier() {
	assert preprocessed('#define f(x) x\nf') == 'f'
	assert preprocessed('#define f(x) x\nf + 1') == 'f + 1'
}

fn test_single_argument() {
	assert preprocessed('#define ID(x) x\nID(42)') == '42'
}

fn test_multiple_arguments() {
	assert preprocessed('#define ADD(a,b) a + b\nADD(1,2)') == '1 + 2'
}

fn test_argument_containing_a_comma_inside_parentheses_is_one_argument() {
	// The depth counter in collect_args is what makes this work.
	assert preprocessed('#define F(x) x\nF((1,2))') == '( 1 , 2 )'
}

fn test_argument_containing_commas_in_brackets() {
	assert preprocessed('#define F(x) x\nF(g(1,2))') == 'g ( 1 , 2 )'
}

fn test_empty_argument() {
	assert preprocessed('#define F(a,b) [a|b]\nF(,x)') == '[ | x ]'
}

fn test_too_few_arguments_is_an_error_and_leaves_the_macro_alone() {
	r := pp('#define F(a,b) a\nF(1)')
	assert r.errors.len > 0
	assert r.text.contains('F')
}

fn test_too_many_arguments_is_an_error() {
	r := pp('#define F(a) a\nF(1,2)')
	assert r.errors.len > 0
}

// --- stringize ---

fn test_stringize_produces_a_string_literal() {
	assert preprocessed('#define S(x) #x\nS(hello)') == '"hello"'
}

fn test_stringize_uses_the_unexpanded_argument() {
	// The argument is *not* macro-expanded before stringizing. If it were, this
	// would be "1" rather than "Y".
	assert preprocessed('#define Y 1\n#define S(x) #x\nS(Y)') == '"Y"'
}

fn test_stringize_keeps_the_spacing_the_argument_had() {
	assert preprocessed('#define S(x) #x\nS( a  b )') == '"a b"'
}

// --- paste ---

fn test_paste_joins_two_tokens() {
	assert preprocessed('#define CAT(a,b) a##b\nCAT(foo,bar)') == 'foobar'
}

fn test_paste_uses_the_unexpanded_argument() {
	assert preprocessed('#define Y 1\n#define CAT(a,b) a##b\nCAT(Y,2)') == 'Y2'
}

fn test_paste_can_build_an_operator() {
	assert preprocessed('#define PLUS(a,b) a##b\nPLUS(+,=)') == '+='
}

// --- variadic macros ---

fn test_variadic_macro_collects_extra_arguments() {
	assert preprocessed('#define F(a,...) [a|__VA_ARGS__]\nF(1,2,3)') == '[ 1 | 2 , 3 ]'
}

fn test_variadic_macro_with_no_extra_arguments() {
	assert preprocessed('#define F(a,...) [a|__VA_ARGS__]\nF(1)') == '[ 1 | ]'
}

fn test_gnu_named_variadic() {
	assert preprocessed('#define F(a,args...) [a|args]\nF(1,2,3)') == '[ 1 | 2 , 3 ]'
}

fn test_gnu_comma_deletion_when_variadic_is_empty() {
	// glibc headers depend on this extension: the comma disappears when nothing
	// follows it.
	assert preprocessed('#define F(a,...) f(a , ## __VA_ARGS__)\nF(1)') == 'f ( 1 )'
	assert preprocessed('#define F(a,...) f(a , ## __VA_ARGS__)\nF(1,2)') == 'f ( 1 , 2 )'
}

// --- conditionals ---

fn test_if_true_branch_is_kept() {
	assert preprocessed('#if 1\nyes\n#endif') == 'yes'
}

fn test_if_false_branch_is_dropped() {
	assert preprocessed('#if 0\nno\n#endif') == ''
}

fn test_else_branch() {
	assert preprocessed('#if 0\nno\n#else\nyes\n#endif') == 'yes'
}

fn test_elif_chain() {
	assert preprocessed('#if 0\na\n#elif 1\nb\n#else\nc\n#endif') == 'b'
	assert preprocessed('#if 0\na\n#elif 0\nb\n#else\nc\n#endif') == 'c'
}

fn test_nested_conditionals() {
	assert preprocessed('#if 1\n#if 0\nno\n#else\nyes\n#endif\n#endif') == 'yes'
}

fn test_defined_operator_both_spellings() {
	assert preprocessed('#define A 1\n#if defined A\nyes\n#endif') == 'yes'
	assert preprocessed('#define A 1\n#if defined(A)\nyes\n#endif') == 'yes'
}

fn test_defined_of_an_undefined_macro_is_false() {
	assert preprocessed('#if !defined(NOPE)\nyes\n#endif') == 'yes'
}

fn test_ifdef_and_ifndef() {
	assert preprocessed('#define A 1\n#ifdef A\nyes\n#endif') == 'yes'
	assert preprocessed('#ifdef NOPE\nno\n#endif\n') == ''
	assert preprocessed('#ifndef NOPE\nyes\n#endif') == 'yes'
}

fn test_ifdef_operand_is_not_expanded() {
	// `#ifdef` must see the name itself, so a macro that would expand to another
	// name must not be followed.
	assert preprocessed('#define B A\n#define A 1\n#ifdef B\nyes\n#endif') == 'yes'
}

fn test_undefined_identifier_in_if_is_zero() {
	assert preprocessed('#if UNDEFINED_THING\nno\n#else\nyes\n#endif') == 'yes'
}

// --- #if arithmetic ---

fn test_arithmetic() {
	assert preprocessed('#if 1 + 2 * 3 == 7\nyes\n#endif') == 'yes'
	assert preprocessed('#if (1 + 2) * 3 == 9\nyes\n#endif') == 'yes'
	assert preprocessed('#if 10 / 3 == 3\nyes\n#endif') == 'yes'
	assert preprocessed('#if 10 % 3 == 1\nyes\n#endif') == 'yes'
}

fn test_bitwise_and_logical() {
	assert preprocessed('#if (1 << 4) == 16\nyes\n#endif') == 'yes'
	assert preprocessed('#if (6 & 3) == 2\nyes\n#endif') == 'yes'
	assert preprocessed('#if (6 | 1) == 7\nyes\n#endif') == 'yes'
	assert preprocessed('#if (6 ^ 3) == 5\nyes\n#endif') == 'yes'
}

fn test_comparison_and_logic() {
	assert preprocessed('#if 1 < 2 && 2 < 3\nyes\n#endif') == 'yes'
	assert preprocessed('#if 1 > 2 || 2 < 3\nyes\n#endif') == 'yes'
	assert preprocessed('#if !0\nyes\n#endif') == 'yes'
	assert preprocessed('#if ~0 != 0\nyes\n#endif') == 'yes'
}

fn test_conditional_operator() {
	assert preprocessed('#if 1 ? 1 : 0\nyes\n#endif') == 'yes'
	assert preprocessed('#if 0 ? 1 : 1\nyes\n#endif') == 'yes'
}

fn test_unsigned_comparison_uses_unsigned_semantics() {
	// -1 is greater than 0 only when the other side is unsigned. Getting this
	// backwards silently changes which branch a real header compiles.
	assert preprocessed('#if -1 > 0u\nyes\n#else\nno\n#endif') == 'yes'
	assert preprocessed('#if -1 > 0\nno\n#else\nyes\n#endif') == 'yes'
}

fn test_division_by_zero_is_reported() {
	r := pp('#if 1 / 0\nx\n#endif')
	assert r.errors.len > 0
}

// --- diagnostics ---

fn test_unterminated_if_is_reported() {
	r := pp('#if 1\nyes\n')
	assert r.errors.len > 0
}

fn test_endif_without_if_is_reported() {
	r := pp('#endif\n')
	assert r.errors.len > 0
}

fn test_else_after_else_is_reported() {
	r := pp('#if 1\n#else\n#else\n#endif\n')
	assert r.errors.len > 0
}

fn test_error_directive_becomes_a_diagnostic() {
	r := pp('#error this is a message\n')
	assert r.errors.len == 1
	assert r.errors[0].contains('this is a message')
}

fn test_unterminated_argument_list_is_reported() {
	r := pp('#define F(a) a\nF(1')
	assert r.errors.len > 0
}

// --- comments and whitespace ---

fn test_directives_inside_a_block_comment_are_not_directives() {
	// A block comment must be removed before directives are recognised, otherwise
	// a commented-out `#define` would take effect.
	assert preprocessed('/* #define A 1 */\nA') == 'A'
}

fn test_line_spliced_directive() {
	assert preprocessed('#def\\\nine A 1\nA') == '1'
}

// --- includes and sentinels ---

fn test_an_included_file_does_not_end_the_translation_unit() {
	// The tokenizer ends every file it reads with an `.eof` sentinel, and the parser
	// treats the first `.eof` as the end of the whole unit. Splicing a header's tokens
	// in therefore used to end the parse at the end of the first include, dropping every
	// declaration after it — silently, because a well-formed stream simply ended.
	dir := os.temp_dir()
	header := dir + os.path_separator + 'vcc_sentinel_probe.h'
	after := dir + os.path_separator + 'vcc_sentinel_probe.c'
	os.write_file(header, 'void included_one(int a);\nvoid included_two(int a);\n') or {
		assert false, 'cannot write the probe header'
		return
	}
	os.write_file(after, '#include "vcc_sentinel_probe.h"\nvoid after_the_include(int a);\n') or {
		assert false, 'cannot write the probe source'
		return
	}
	defer {
		os.rm(header) or {}
		os.rm(after) or {}
	}

	mut p := preprocessor([dir], [])
	p.define_builtins()
	r := p.run(after)
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'

	// One sentinel, at the very end.
	mut sentinels := 0
	for i, tok in r.tokens {
		if tok.kind == .eof {
			sentinels++
			assert i == r.tokens.len - 1, 'the only eof token must be the last one'
		}
	}
	assert sentinels == 1, 'expected exactly one eof token, got ${sentinels}'

	parsed := parse_tokens(r.tokens, after, p.packs)
	assert parsed.errors.len == 0, 'unexpected diagnostics: ${parsed.errors}'
	assert parsed.globals.len == 3, 'got ${parsed.globals.len} declarations'
	assert parsed.globals[2].name == 'after_the_include'
}

fn test_a_macro_expansion_does_not_end_the_translation_unit() {
	// The same sentinel arrives with a macro body, so a translation unit whose first
	// declaration used a macro parsed as that declaration and stopped.
	//
	// The helper is spelled out rather than shared with `parser_test.v`, because each
	// `_test.v` file is its own compilation unit and does not see the others.
	mut p := preprocessor([], [])
	p.define_builtins()
	r := p.run_text('#define NOTE "n"\nconst char *a = NOTE;\nint b;\nint c;\n',
		'test.c')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	parsed := parse_tokens(r.tokens, 'test.c', p.packs)
	assert parsed.errors.len == 0, 'unexpected diagnostics: ${parsed.errors}'
	mut names := []string{}
	for obj in parsed.globals {
		names << obj.name
	}
	assert names.contains('b'), 'got ${names}'
	assert names.contains('c'), 'got ${names}'
}
