module ast

// Token and file position types.
//
// A separate `pos` type rather than a bare integer, because every diagnostic in a
// compiler is only as good as its position, and an integer invites off-by-one
// errors that a struct makes impossible.

pub type Pos = i32

pub const invalid_pos = Pos(-1)

pub struct File {
pub mut:
	name string
	// file_no and display_no differ: a header included twice is one file but may
	// appear in diagnostics twice.
	file_no    int
	display_no int
	// contents is the whole file text. A tokenizer indexes into this rather than
	// copying substrings, which keeps memory flat for the large generated C that V
	// produces.
	contents   string
	line_delta int
}

pub struct Line {
pub mut:
	// file is None only for a synthesized location.
	file ?&File
	// disp_line is the line as the user should see it, which differs from the
	// physical line once `#line` has been used.
	disp_line int
	disp_col  int
}

// Token is one lexical token.
pub struct Token {
pub mut:
	kind TokenKind
	// text is the raw spelling, needed for identifiers, numbers and literals.
	text string
	// val is the decoded value of a numeric or character literal.
	val i64
	// fval is the decoded value of a floating literal.
	fval f64
	loc  Pos
	len  int
	// line is where the token starts. It is a value rather than a pointer because
	// every token the tokenizer produces has a position, so an option would only
	// add an unwrap at every diagnostic site.
	line Line
	// at_bol marks the first token of a source line, which the preprocessor needs
	// to reconstruct directives.
	at_bol bool
	// has_space marks that whitespace preceded the token, which `#` stringizing
	// needs in order to reproduce it.
	has_space bool
	// is_keyword distinguishes a keyword from an identifier with the same text.
	is_keyword bool
	// str_data is the decoded bytes of a string literal, without its terminator.
	str_data []u8
	// origin is the token this one was macro-expanded from, if any. Without it a
	// macro diagnostic points at the expansion rather than the real source.
	origin ?&Token
}

// is_ident reports whether the token names something: an identifier or a keyword.
pub fn (t &Token) is_ident() bool {
	return t.kind in [.ident, .keyword]
}

// str returns the spelling. For a macro-expanded token the spelling must come from
// the origin, so that a diagnostic quotes what the programmer wrote.
pub fn (t &Token) str() string {
	if t.origin != none {
		return t.origin!.str()
	}
	return t.text
}

pub enum TokenKind {
	ident
	keyword
	punct
	str_
	num_
	// eof is the single sentinel that terminates every stream.
	eof
	// preproc_any carries a `#` line the preprocessor has not expanded yet.
	preproc_any
	// newline is emitted inside a directive line and never reaches the parser.
	newline
}

// Keyword is the set of reserved words.
//
// `do_` and `volatile_` carry a trailing underscore because `do` and `volatile` are
// reserved words in V itself and cannot be enum field names. `keyword_name` maps
// them back to the C spelling, so the underscore never reaches generated code.
//
// Every enum in this program is declared in the module-level `pub enum Name { }`
// form. That is a constraint of the V build this project targets: `pub type X =
// enum { ... }` and `pub type X = enum u8 { ... }` are both rejected in a way that
// leaves `X` undefined, and a bare `enum { ... }` is a parse error. Do not rewrite
// these as type aliases.
pub enum Keyword {
	auto_
	break_
	case_
	char_
	const_
	continue_
	default_
	do_
	double_
	else_
	enum_
	extern_
	float_
	for_
	goto_
	if_
	inline_
	int_
	long_
	register_
	return_
	short_
	signed_
	sizeof_
	static_
	struct_
	switch_
	typedef_
	union_
	unsigned_
	void_
	volatile_
	while_

	// C11
	alignas
	alignof
	atomic
	bool_
	generic
	noreturn
	static_assert
	thread_local

	// GNU extensions V's generated C relies on. See docs/CONTRACT.md section 4.
	attribute
	typeof
	asm_
	extension_
	restrict_
	va_arg
	// The other three variadic builtins. They are separate keywords rather than one
	// `va_other` because each takes a different argument shape: `va_start` and
	// `va_copy` take two operands, `va_end` takes one, and folding them together
	// would mean the parser branches on arity anyway while losing the name it reports.
	va_start
	va_copy
	va_end
	// va_list is a *type* name, not a function: `typedef __builtin_va_list va_list;`
	// is the entire body of the `stdarg.h` this target ships, so it has to resolve in
	// `declspec` rather than as an expression.
	va_list_
	offsetof
	types_compatible_p
	constant_p
}

// keyword_name returns the C spelling of a keyword.
//
// This is a `match` rather than a lookup table on purpose. A `const map[Keyword]string`
// was tried first and is broken in this V build: a 50-entry literal produced a
// 43-entry map whose values were misaligned with their keys, so indexing it with
// `.case_` returned the value belonging to `.while_`. That is a silent
// miscompilation, not a compile error, so it is recorded in notes/DECISIONS.md.
// A `match` also avoids hashing on every identifier token, which is the hot path
// of any lexer.
pub fn keyword_name(k Keyword) string {
	return match k {
		.auto_ { 'auto' }
		.break_ { 'break' }
		.case_ { 'case' }
		.char_ { 'char' }
		.const_ { 'const' }
		.continue_ { 'continue' }
		.default_ { 'default' }
		.do_ { 'do' }
		.double_ { 'double' }
		.else_ { 'else' }
		.enum_ { 'enum' }
		.extern_ { 'extern' }
		.float_ { 'float' }
		.for_ { 'for' }
		.goto_ { 'goto' }
		.if_ { 'if' }
		.inline_ { 'inline' }
		.int_ { 'int' }
		.long_ { 'long' }
		.register_ { 'register' }
		.return_ { 'return' }
		.short_ { 'short' }
		.signed_ { 'signed' }
		.sizeof_ { 'sizeof' }
		.static_ { 'static' }
		.struct_ { 'struct' }
		.switch_ { 'switch' }
		.typedef_ { 'typedef' }
		.union_ { 'union' }
		.unsigned_ { 'unsigned' }
		.void_ { 'void' }
		.volatile_ { 'volatile' }
		.while_ { 'while' }
		.alignas { '_Alignas' }
		.alignof { '_Alignof' }
		.atomic { '_Atomic' }
		.bool_ { '_Bool' }
		.generic { '_Generic' }
		.noreturn { '_Noreturn' }
		.static_assert { '_Static_assert' }
		.thread_local { '_Thread_local' }
		.attribute { '__attribute__' }
		.typeof { 'typeof' }
		.asm_ { '__asm__' }
		.extension_ { '__extension__' }
		.restrict_ { 'restrict' }
		.va_arg { '__builtin_va_arg' }
		.va_start { '__builtin_va_start' }
		.va_copy { '__builtin_va_copy' }
		.va_end { '__builtin_va_end' }
		.va_list_ { '__builtin_va_list' }
		.offsetof { '__builtin_offsetof' }
		.types_compatible_p { '__builtin_types_compatible_p' }
		.constant_p { '__builtin_constant_p' }
	}
}

// keyword_from_spelling returns the keyword for an exact C spelling, or none.
//
// The alternative spellings GCC accepts are handled by the tokenizer, which folds
// `__inline__` and `__inline` into one keyword before calling this.
pub fn keyword_from_spelling(text string) ?Keyword {
	return match text {
		'auto' { Keyword.auto_ }
		'break' { Keyword.break_ }
		'case' { Keyword.case_ }
		'char' { Keyword.char_ }
		'const' { Keyword.const_ }
		'continue' { Keyword.continue_ }
		'default' { Keyword.default_ }
		'do' { Keyword.do_ }
		'double' { Keyword.double_ }
		'else' { Keyword.else_ }
		'enum' { Keyword.enum_ }
		'extern' { Keyword.extern_ }
		'float' { Keyword.float_ }
		'for' { Keyword.for_ }
		'goto' { Keyword.goto_ }
		'if' { Keyword.if_ }
		'inline' { Keyword.inline_ }
		'int' { Keyword.int_ }
		'long' { Keyword.long_ }
		'register' { Keyword.register_ }
		'return' { Keyword.return_ }
		'short' { Keyword.short_ }
		'signed' { Keyword.signed_ }
		'sizeof' { Keyword.sizeof_ }
		'static' { Keyword.static_ }
		'struct' { Keyword.struct_ }
		'switch' { Keyword.switch_ }
		'typedef' { Keyword.typedef_ }
		'union' { Keyword.union_ }
		'unsigned' { Keyword.unsigned_ }
		'void' { Keyword.void_ }
		'volatile' { Keyword.volatile_ }
		'while' { Keyword.while_ }
		'_Alignas' { Keyword.alignas }
		'_Alignof' { Keyword.alignof }
		'_Atomic' { Keyword.atomic }
		'_Bool' { Keyword.bool_ }
		'_Generic' { Keyword.generic }
		'_Noreturn' { Keyword.noreturn }
		'_Static_assert' { Keyword.static_assert }
		'_Thread_local' { Keyword.thread_local }
		'__attribute__' { Keyword.attribute }
		'typeof' { Keyword.typeof }
		'__asm__' { Keyword.asm_ }
		'__extension__' { Keyword.extension_ }
		'restrict' { Keyword.restrict_ }
		'__restrict' { Keyword.restrict_ }
		'__restrict__' { Keyword.restrict_ }
		'__builtin_va_arg' { Keyword.va_arg }
		'__builtin_va_start' { Keyword.va_start }
		'__builtin_va_copy' { Keyword.va_copy }
		'__builtin_va_end' { Keyword.va_end }
		'__builtin_va_list' { Keyword.va_list_ }
		'__builtin_offsetof' { Keyword.offsetof }
		'__builtin_types_compatible_p' { Keyword.types_compatible_p }
		'__builtin_constant_p' { Keyword.constant_p }
		else { none }
	}
}
