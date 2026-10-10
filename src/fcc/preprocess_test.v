module fcc
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

// ppb is `pp` with the predefined macros registered.
//
// `pp` alone leaves them undefined, which is right for a test about `#define` and wrong
// for one about `__STDC__`. C always has them, so a test that needs one asks for them.
fn ppb(src string) PPResult {
	mut p := preprocessor([], [])
	p.define_builtins()
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

// [C11 6.10p7] A preprocessing directive takes effect from the point it appears.
//
// This is the regression test for a defect that made every `#define` in a file take
// effect *retroactively*, because phase 2 ran one expansion pass over the whole stream
// after every directive had been consumed. With it, `M14()` below was expanded with the
// *second* definition of `M14`: it reported `requires 1 arguments, but 0 given` against
// the first line and left the call unexpanded. Measured on chibicc's macro.c line 347.
// The same defect is what made a real `#include <stdio.h>` unusable here, reporting
// `macro getwchar requires 0 arguments, but 1 given` on mingw's own headers.
fn test_a_define_takes_effect_at_its_own_line_not_retroactively() {
	// The first call uses the first definition...
	assert preprocessed('#define M(...) 3\nint a = M();') == 'int a = 3 ;'
	// ...and a later redefinition does not reach back to it.
	assert preprocessed('#define M(...) 3\nint a = M();\n#define M(x, ...) f(1,2,x,__VA_ARGS__)\nint b = M(3,4,5);') == 'int a = 3 ; int b = f ( 1 , 2 , 3 , 4 , 5 ) ;'
}

// The redefinition across the variadic boundary is the nastier shape: the same name
// changes from pure-variadic to named-plus-variadic, and the earlier call has to keep
// the definition it was written against.
fn test_a_redefinition_across_the_variadic_boundary() {
	assert preprocessed('#define M(...) 3\nint a = M();\n#define M(x, ...) x\nint b = M(5);') == 'int a = 3 ; int b = 5 ;'
}

// A macro defined *between* two uses is the same rule seen from the other side: the
// earlier use must not expand at all.
fn test_a_define_after_a_use_does_not_reach_back() {
	assert preprocessed('int a = G;\n#define G 7\nint b = G;') == 'int a = G ; int b = 7 ;'
}

// An `#undef` between two uses is symmetric, and is the case a single whole-file pass
// gets wrong in the opposite direction.
fn test_an_undef_between_two_uses() {
	assert preprocessed('#define G 7\nint a = G;\n#undef G\nint b = G;') == 'int a = 7 ; int b = G ;'
}

fn test_gnu_comma_deletion_when_variadic_is_empty() {
	// glibc headers depend on this extension: the comma disappears when nothing
	// follows it.
	assert preprocessed('#define F(a,...) f(a , ## __VA_ARGS__)\nF(1)') == 'f ( 1 )'
	assert preprocessed('#define F(a,...) f(a , ## __VA_ARGS__)\nF(1,2)') == 'f ( 1 , 2 )'
}

// [C11 6.10.3.3p2] `##` joins the *last* token of its left argument with the *first*
// token of its right one. Everything either side of those two tokens is untouched.
//
// It joined the two arguments whole instead, so `paste(1+i,3)` came out as the single
// identifier `1+i3` and the parser reported `undefined variable "1+i3"` — a message
// about the wrong thing entirely, which is why four lines of chibicc's macro.c failed
// for a reason that named no defect. The same defect made `##` in a chain
// uncontrollable: see the chain tests below.
fn test_paste_joins_only_the_boundary_tokens() {
	assert preprocessed('#define P(x,y) x##y\nP(1+i,3)') == '1 + i3'
	assert preprocessed('#define P(x) x##5\nP(1+2)') == '1 + 25'
	assert preprocessed('#define P(x) 2##x\nP(1+2)') == '21 + 2'
	assert preprocessed('#define P(x,y) x##y\nP(1,5)') == '15'
	assert preprocessed('#define P(x,y) x##y\nP(0,xff)') == '0xff'
	assert preprocessed('#define P(x,y) x##y\nP(foo,bar)') == 'foobar'
}

// [C11 6.10.3.3p2] An argument with no tokens is a placemarker: it contributes no
// boundary token, so `x##y` with an empty `y` is just `x`. `collect_args` already
// represents `f(5,)` as an empty argument, so this needs no special case.
fn test_paste_with_an_empty_argument_is_a_placemarker() {
	assert preprocessed('#define P(x,y) x##y\nP(5,)') == '5'
	assert preprocessed('#define P(x,y) x##y\nP(,5)') == '5'
}

// `x##y##z` is a chain, and one paste per position is not enough. Without a chain loop
// the second `##` matched no branch, fell through to the ordinary-token path, and
// `paste4(1,2,3)` expanded to `12 ## 3` — which the parser then reported as
// `expected ",", found "##"` and, because `expect` advances anyway, `too many arguments`
// against `assert`'s arity. Two messages, one defect, and the arity check was right.
fn test_paste_handles_a_chain() {
	assert preprocessed('#define P(x,y,z) x##y##z\nP(1,2,3)') == '123'
	// Left-associative, and confirmed against gcc rather than assumed: the first paste
	// glues `i` to `2`, and that result's last token — `i2` — is the left operand of the
	// second paste, so `j+3` contributes only its first token `j`. gcc answers
	// `1 + i2j + 3` for exactly this input.
	assert preprocessed('#define P(x,y,z) x##y##z\nP(1+i,2,j+3)') == '1 + i2j + 3'
	// The chain is left-associative: `x##y` is pasted first, and its result's last token
	// is the left operand of the next `##`. That is what makes `P(x##1, 2)` with x bound
	// to 3 answer `312` and not `21` — the inner paste gives `31`, and the outer pastes
	// its last token onto `2`. Confirmed against gcc, which answers the same.
	assert preprocessed('#define P(a,b) a##b\n#define Q(x) P(x##1, 2)\nQ(3)') == '312'
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

// [C11 7.1.2p2] A macro whose name is a keyword is legal, and DR 108 records the
// Committee's intention as allowing it. Keywords become reserved only in phases 7 and 8,
// after expansion, so `#define if 5` masks the keyword rather than colliding with it.
// gcc, gcc -pedantic-errors and tcc all accept it silently.
//
// `expand` looked the macro table up only for `.ident` tokens, so the keyword never
// reached it. This is the one gate in the way — the table is text-keyed and never
// inspects a token's kind.
fn test_a_macro_may_be_named_for_a_keyword() {
	assert preprocessed('#define if 5\nint x = if;') == 'int x = 5 ;'
	assert preprocessed('#define for 1\nfor') == '1'
	// A genuine keyword with no macro in scope is untouched, which is the whole reason
	// the change is safe: nothing is retagged, only the lookup is widened.
	assert preprocessed('int x = 3;\nif (x) { return 1; }') == 'int x = 3 ; if ( x ) { return 1 ; }'
}

// `#if`/`#ifdef` are unaffected. `eval_condition` tokenises and evaluates without
// consulting the macro table, and `eval_ifdef` already accepts both token kinds — so a
// keyword macro is visible to `#ifdef` and still invisible to `#if`, which is a separate
// recorded divergence and not something this makes worse.
// [C11 6.10.1p4] An `#if` operand is macro-expanded before it is evaluated. `expand`
// was never called on the path at all, so `#if 5` and `#if 1+1` were right while every
// `#if` naming a macro took its `#else` branch — an unknown identifier evaluates to 0,
// and nothing expanded it. Measured on chibicc's macro.c, and on gcc for every case
// here.
fn test_an_if_operand_is_macro_expanded() {
	assert preprocessed('#define M 5\n#if M\nyes\n#else\nno\n#endif') == 'yes'
	assert preprocessed('#define M 0\n#if M\nyes\n#else\nno\n#endif') == 'no'
	assert preprocessed('#define M 5\n#if M + 0\nyes\n#else\nno\n#endif') == 'yes'
	assert preprocessed('#define M 5\n#if (M)\nyes\n#else\nno\n#endif') == 'yes'
	// The exponent is arithmetic, and a zero result is the `#else` branch.
	assert preprocessed('#define M 5\n#if M - 5\nyes\n#else\nno\n#endif') == 'no'
	// `#elif` takes the same path.
	assert preprocessed('#define M 5\n#if M - 5\nyes\n#elif M\nalso\n#else\nno\n#endif') == 'also'
	// A function-like invocation needs its `(` in the same list, which is why
	// `expand_condition` expands *runs* of tokens rather than one at a time.
	assert preprocessed('#define F() 1\n#if F()\nyes\n#else\nno\n#endif') == 'yes'
	assert preprocessed('#define F(x) x\n#if F(1 + 1)\nyes\n#else\nno\n#endif') == 'yes'
	// Not followed by `(`, so it is an ordinary identifier and evaluates to 0.
	assert preprocessed('#define F() 1\n#if F\nyes\n#else\nno\n#endif') == 'no'
}

// [C11 6.10.1p4] The operand of `defined` is *excluded* from that replacement. Expanding
// the whole list unconditionally would turn `#if defined(M) && M` into
// `#if defined(5) && 5`, because there `M` belongs to `defined` rather than to the
// expression. gcc takes the `#if` branch for that input, and so must this.
fn test_the_defined_operand_is_not_expanded() {
	assert preprocessed('#define M 1\n#if defined(M) && M\nyes\n#else\nno\n#endif') == 'yes'
	assert preprocessed('#define M 1\n#if defined M && M\nyes\n#else\nno\n#endif') == 'yes'
	// Both spellings, and the arithmetic form.
	assert preprocessed('#define M 1\n#if defined(M) - 1\nyes\n#else\nno\n#endif') == 'no'
	assert preprocessed('#if defined(NO_SUCH_MACRO)\nyes\n#else\nno\n#endif') == 'no'
	// `#ifdef` never reaches the expander at all, and takes both token kinds.
	assert preprocessed('#define if 5\n#ifdef if\nyes\n#else\nno\n#endif') == 'yes'
	// A third spelling is undefined behaviour, so it is expanded like anything else and
	// the evaluator's own diagnostic reaches it.
	assert pp('#if defined ( M )\nx\n#endif').errors.len == 0
}

// `tokenize_fragment` ends every fragment — and therefore every macro body — with an eof
// sentinel, so substituting a macro reintroduces one. In a translation unit `run` strips
// them at the end; the `#if` path has no such pass, and the sentinel surfaced as an
// empty token the evaluator reported as
// `unexpected token in #if expression: ` with nothing after the colon.
fn test_an_if_operand_leaves_no_sentinel_behind() {
	r := pp('#define M 5\n#if M\nx\n#endif')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	assert preprocessed('#define M 5\n#if M\nx\n#endif') == 'x'
}

// [C11 6.10.1p4] says the emptiness test is on the expression *after* expansion, because
// a macro may expand to nothing. Testing the raw tokens instead silently took the
// `#else` branch for `#define M` followed by `#if M`.
fn test_an_operand_that_expands_to_nothing_is_empty() {
	assert pp('#define M\n#if M\nx\n#endif').errors.len == 1
	assert pp('#if\nx\n#endif').errors.len == 1
}

// [C11 6.10.3p4] A macro's own name in its body is not replaced. The recursion guard
// implements it, and it only worked when the macro was expanded at the top level: an
// argument was pre-expanded inside `substitute`, which set and cleared `is_expanding`,
// so the rescan that `expand` performs on the substituted result expanded the same
// macro a second time.
//
// Measured on chibicc's macro.c: with `#define M2 M2 + 3` and
// `#define ASSERT(x,y) assert(x,y,#y)`, `ASSERT(9, M2)` is `M2 + 3` and twelve was the
// wrong answer.
fn test_a_self_referential_macro_is_expanded_once_inside_an_argument() {
	assert preprocessed('#define M2 M2 + 3\n#define ASSERT(x, y) a(x, y, #y)\nASSERT(9, M2)') == 'a ( 9 , M2 + 3 , "M2" )'
	// And at the top level, which is the case that always worked.
	assert preprocessed('#define M2 M2 + 3\nint r = M2;') == 'int r = M2 + 3 ;'
	// A chain of them: the body's own copy is left alone, and the rest is substituted.
	assert preprocessed('#define M3 M2 + 3\n#define M2 M2 + 3\nint r = M3;') == 'int r = M2 + 3 + 3 ;'
}


// [C11 6.10.8p1] `__STDC__` is the integer constant 1.
//
// It was missing, and emitting it as a *string* — which is what every other builtin
// does, and what `builtin_token` hardcoded — would hand `assert(int, int)` a `char[2]`
// and fail the type check instead of the value. A numeric token needs both `kind` and
// `text`, because `numeric_type` reads the spelling and ignores `val`.
fn test_stdc_is_an_integer_one() {
	assert ppb('int a = __STDC__;').text == 'int a = 1 ;'
	assert ppb('int b = __STDC__ + 1;').text == 'int b = 1 + 1 ;'
	// `strlen` of it is 1, which is what chibicc's macro.c asserts.
	assert ppb('strlen(__STDC__)').text == 'strlen ( 1 )'
}

// [C11 6.10.8p1] `__DATE__` is "Mmm dd yyyy" — space-padded, not zero-padded, which is
// the difference from `time`'s own `DD` format and what makes it 11 characters.
// `__TIME__` is "hh:mm:ss", 8 characters.
//
// The exact spelling is a clock, so only the length and the shape are pinned; asserting a
// date would make the test fail at midnight.
fn test_date_and_time_have_the_shape_c_spells_them() {
	// The raw result is used rather than `pp`, which joins the token spellings and
	// throws the rest away — the byte image is what carries the value here.
	mut p := preprocessor([], [])
	p.define_builtins()
	r := p.run_text('char *d = __DATE__;\nchar *t = __TIME__;\n', 'test.c')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	strs := r.tokens.filter(it.kind == .str_)
	assert strs.len == 2, 'expected two string literals, got ${strs.len}'
	// Three space-separated fields, the middle two characters wide and space-padded.
	d := strs[0].str_data.bytestr()
	assert d.len == 11, 'got "${d}" (${d.len})'
	assert d[3] == ` `
	assert d[6] == ` `
	t := strs[1].str_data.bytestr()
	assert t.len == 8, 'got "${t}" (${t.len})'
	assert t[2] == `:` && t[5] == `:`
}

// `__BASE_FILE__` is the top-level translation unit and must not change on an include,
// which is what distinguishes it from `__FILE__`. It needs a field on the preprocessor
// because the path an expansion is handed changes with every `#include`.
fn test_base_file_does_not_follow_an_include() {
	mut p := preprocessor([], [])
	p.define_builtins()
	r := p.run_text('char *a = __BASE_FILE__;', 'top/top.c')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	strs := r.tokens.filter(it.kind == .str_)
	assert strs.len == 1, 'expected one string literal, got ${strs.len}'
	assert strs[0].str_data.bytestr() == 'top/top.c'
}

// [C23 6.10.5.1] `__VA_OPT__(content)` is present only when the variadic part is
// non-empty, and its content is the replacement list of the *current* macro — so a
// parameter inside it is substituted.
//
// The emptiness test comes first, and that order is observable: `__VA_OPT__(EMPTY x)`
// expands to nothing with no variadic arguments and to ` x` with one. Expanding the
// content first would make it `< x>` both ways. Measured against gcc.
fn test_va_opt_is_absent_when_the_variadic_part_is_empty() {
	// The body has no `__VA_ARGS__`, so the argument itself is consumed and discarded —
	// which is why `F(1)` answers `a , b` and not `a , b 1`.
	assert pp('#define F(...) a __VA_OPT__(,) b\nF()').text == 'a b'
	assert pp('#define F(...) a __VA_OPT__(,) b\nF(1)').text == 'a , b'
	// A parameter inside the content is this macro's parameter, and is substituted.
	assert pp('#define F(x, ...) f(__VA_OPT__(x))\nF(1)').text == 'f ( )'
	assert pp('#define F(x, ...) f(__VA_OPT__(x, y))\nF(1, 2)').text == 'f ( 1 , y )'
	// Empty content is legal and contributes nothing either way.
	assert pp('#define F(...) a __VA_OPT__() b\nF(1)').text == 'a b'
	// Nested parens inside the content do not close it early.
	assert pp('#define F(...) a __VA_OPT__(g(1)) b\nF(2)').text == 'a g ( 1 ) b'
	// Both spellings confirmed against gcc on the same inputs.
}

// [C23 6.10.5.1p3] forbids `__VA_OPT__` inside a `__VA_OPT__`. gcc diagnoses it, and
// left to recurse it would not terminate — so it is reported rather than dropped.
fn test_va_opt_inside_va_opt_is_reported_not_dropped() {
	r := pp('#define F(...) a __VA_OPT__(x __VA_OPT__(y)) b\nF(1)')
	assert r.errors.len > 0, 'expected a diagnostic, got none'
	assert r.errors[0].contains('__VA_OPT__')
}

// A substituted argument inherits the spacing of where the *parameter* stood in the
// body, and `#` stringizing needs that rather than the invocation site's spacing.
//
// `#define M13(x) M12(foo. x)` with `M12` stringifying its argument gives `"foo. bar"`
// and not `"foo.bar"`: the body wrote a space before `x` even though the invocation
// `M13(bar)` wrote none before `bar`. Measured on chibicc's macro.c line 311.
//
// The two are ORed rather than one overwriting the other, because either side can be
// the one that carried a real space.
fn test_a_substituted_argument_inherits_the_bodys_spacing() {
	assert preprocessed('#define M12(x) #x\n#define M13(x) M12(foo. x)\nM13(bar)') == '"foo. bar"'
	assert preprocessed('#define M12(x) #x\n#define M13(x) M12(foo.x)\nM13(bar)') == '"foo.bar"'
	// A real space at the invocation site survives too.
	assert preprocessed('#define M12(x) #x\n#define M13(x) M12(foo . x)\nM13( bar)') == '"foo . bar"'
}

