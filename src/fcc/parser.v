module fcc
import ast

// The declaration half of the parser.
//
// It is chibicc's `parse.c` restricted to declarations: declspec, declarators,
// struct, union, enum, typedef, attributes, `typeof`, initializers, and the
// constant-expression evaluator they all need. Expressions and statements are the
// next slice.
//
// The restriction has one consequence worth stating up front. An initializer's
// elements are expressions, and chibicc parses them with its full expression
// grammar. Here only *constant* expressions are parsed, because that is all a
// global initializer may legally contain, and it is also all an array bound, an
// enum value, a bitfield width and a `sizeof` needs. A non-constant form — a
// function call, an assignment — is recorded as a `.generic` node with a
// diagnostic, so a corpus sweep finds every one of them instead of stopping at
// the first.
//
// Two things are parsed rather than skipped: a function's parameter list, because
// its types are declarations; and its body's token extent, which is recorded on
// the object so the next slice resumes there rather than re-reading the file.

// VarScope is what one name means in one block scope: a variable, a typedef, or
// an enumeration constant.
struct VarScope {
mut:
	name string
	obj  &ast.Obj = unsafe { nil }
	// type_def is an option, not a bare pointer. Returning a bare nil pointer from a
	// `?&T` function yields `some(nil)` rather than `none` in this V build — measured
	// with a two-line probe, where `f(s) == none` printed false — and `some(nil)`
	// survives `or { default }`, so `find_typedef` would report a variable as a type
	// name and `declspec` would hand on a nil type. Storing the option keeps `none`
	// and `some` distinguishable.
	type_def ?&ast.Type = none
	// enum_ty is non-nil when the name is an enumeration constant, and is the
	// enum the constant belongs to. `enum_val` is only then meaningful.
	enum_ty  &ast.Type = unsafe { nil }
	enum_val i64
}

// Scope is one block. C has two namespaces per block, so a struct tag and a
// variable of the same name do not collide, and this keeps them apart.
struct Scope {
mut:
	vars map[string]&VarScope
	tags map[string]&ast.Type
}

// VarAttr carries the storage class and alignment of a declaration. They are not
// part of the type, because `static int x` and `int x` are the same type.
struct VarAttr {
mut:
	is_typedef bool
	is_static  bool
	is_extern  bool
	is_inline  bool
	is_tls     bool
	align      int
}

// Initializer is one node of the initializer tree. An initializer nests because an
// aggregate can be initialized by an aggregate: `int x[2][2] = {{1,2},{3,4}}`.
struct Initializer {
mut:
	ty &ast.Type = unsafe { nil }
	// is_flexible marks an aggregate whose extent the initializer has yet to
	// decide, which is how `int x[] = {1,2,3}` learns its length.
	is_flexible bool
	// expr is the initializing expression of a scalar, or of an aggregate that is
	// initialized from a single value of the same struct type.
	expr &ast.Node = unsafe { nil }
	// children are the element initializers of an array or struct.
	children []&Initializer
	// mem_index is the index of the union member being initialized, or -1.
	mem_index int = -1
}

// StaticInit is a static local whose initializer has been parsed but whose byte image
// has not been written.
//
// It is kept rather than dropped because the tree is the only thing that still refers
// to the label-as-value nodes inside it, and the byte image reads `unique_label` off
// them — which is empty until `resolve_goto_labels` has run.
struct StaticInit {
mut:
	obj  &ast.Obj
	init &Initializer
	ty   &ast.Type
}

// InitDesg is a step in the chain of lvalues an initializer writes through, for
// example `x` then `x[2]` then `x[2].b` for `struct S x[3]`.
//
// `@[heap` because each step holds a reference to the one before it, and those steps
// live for as long as the initializer tree that created them.
@[heap]
struct InitDesg {
mut:
	next &InitDesg = unsafe { nil }
	idx  int
	// member is the struct field this step names, or none when the step is an array
	// index or the object itself.
	member ?&ast.Member
	obj    &ast.Obj = unsafe { nil }
}

// ParseResult is what parsing one translation unit produced. It is not called Result because
// the preprocessor already has one of those in this module.
pub struct ParseResult {
pub mut:
	globals  []&ast.Obj
	errors   []string
	warnings []string
}

// Parser holds the state of one parse.
//
// The token stream is a slice with an index rather than a linked list, and parsing
// functions move `pos` themselves instead of returning "the rest of the input".
// chibicc threads a `Token **rest` through every function; with a mutable struct
// that becomes the same thing without a second return value at every level.
pub struct Parser {
pub mut:
	toks []ast.Token
	pos  int
	// path names the file the tokens came from, for diagnostics.
	path string
	// scopes is a stack; the last entry is the innermost block.
	scopes  []Scope
	globals []&ast.Obj
	locals  []&ast.Obj
	// builtin_alloca is the object the VLA translation refers to. It is declared by
	// the parser rather than by any C source.
	builtin_alloca &ast.Obj = unsafe { nil }
	errors         []string
	warnings       []string
	// quiet suppresses diagnostics while the parser speculates — looking ahead to
	// decide whether a declaration is a function, for instance. Speculation must
	// not report, or every lookahead would double every error.
	quiet int
	// counter names anonymous globals.
	counter int
	// current_fn is the function whose body is being parsed, which is what a `return`
	// casts to and what a parameter list is attached to.
	current_fn &ast.Obj = unsafe { nil }
	// current_switch is the innermost `switch`, which a `case` attaches itself to.
	current_switch &ast.Node = unsafe { nil }
	// brk_label and cont_label are the labels `break` and `continue` jump to. They
	// are resolved while parsing because a one-pass backend cannot invent them later,
	// and a `break` outside any loop is an error rather than a label to nowhere.
	brk_label  string
	cont_label string
	// gotos and labels collect the two halves of a goto so that a forward reference
	// can be resolved once the whole body has been read.
	gotos  []&ast.Node
	labels []&ast.Node
	// deferred_static_inits holds the static locals of the function being parsed,
	// whose byte images are written by `flush_static_inits` once its labels exist.
	deferred_static_inits []StaticInit
	// packs are the `#pragma pack` events the preprocessor saw, in order.
	packs []PackEvent
}

// parse_tokens parses a preprocessed token stream into global declarations.
//
// `packs` carries the `#pragma pack` state, which the preprocessor sees and the
// layout code needs; see `Parser.pack_at`.
pub fn parse_tokens(toks []ast.Token, path string, packs []PackEvent) ParseResult {
	mut p := Parser{
		toks:    toks
		path:    path
		packs:   packs
		scopes:  [
			Scope{
				vars: map[string]&VarScope{}
				tags: map[string]&ast.Type{}
			},
		]
		globals:  []&ast.Obj{}
		locals:   []&ast.Obj{}
		errors:   []string{}
		warnings: []string{}
	}
	p.translation_unit()
	p.scan_globals()
	return ParseResult{
		globals:  p.globals
		errors:   p.errors
		warnings: p.warnings
	}
}

// --- token access ---

// tok is the token at the cursor.
// tok is the token at the cursor.
//
// Clamped to the last token, because `expect` advances even on a token it did not
// expect, and at the end of a file that walks the cursor one past the `.eof` sentinel.
// Reading there has to give the sentinel rather than run off the array.
fn (p &Parser) tok() ast.Token {
	if p.pos >= p.toks.len {
		return p.toks[p.toks.len - 1]
	}
	return p.toks[p.pos]
}

// tok_at is the token n positions ahead, clamped to the last one so that lookahead
// at the end of a file reads the eof sentinel rather than running off.
fn (p &Parser) tok_at(n int) ast.Token {
	mut i := p.pos + n
	if i >= p.toks.len {
		i = p.toks.len - 1
	}
	return p.toks[i]
}

// at reports whether the token at the cursor has this spelling.
//
// It compares the raw spelling rather than a keyword's canonical name, because
// GNU accepts several spellings of the same keyword (`restrict`, `__restrict`,
// `__restrict__`) and every place that cares names the ones it accepts — which is
// what chibicc does too.
fn (p &Parser) at(text string) bool {
	return p.tok().text == text
}

fn (p &Parser) at_kw(n int) bool {
	return p.tok_at(n).kind == .keyword
}

// next consumes and returns the token at the cursor.
fn (mut p Parser) next() ast.Token {
	t := p.toks[p.pos]
	if t.kind != .eof {
		p.pos++
	}
	return t
}

// consume consumes the token at the cursor if it has this spelling.
fn (mut p Parser) consume(text string) bool {
	if !p.at(text) {
		return false
	}
	p.pos++
	return true
}

// expect consumes a token that must have this spelling.
//
// The token is read *before* the cursor moves, and the cursor is advanced *outside* the
// branch. Both halves matter: this V build loses a receiver-field write that is followed
// by a read of the receiver's slice field in the same method, which is exactly what
// reading `p.toks[p.pos]` after `p.pos++` looks like. See notes/DECISIONS.md.
//
// A mismatch is reported and the cursor is left where it was, rather than consuming
// something that is probably the start of the next declaration. That choice is what
// keeps a malformed declaration from eating the rest of the file.
// expect consumes the token the cursor must be on.
//
// It advances even when the token is wrong, which is what guarantees the parser makes
// progress through a malformed input. Reporting without consuming lets an enclosing
// loop see the same token again, parse it again, and report again: `sizeof("a" "b")`
// did exactly that, appending diagnostics until the heap gave out, which surfaced as a
// garbage-collection abort rather than as the one-line syntax error it was.
fn (mut p Parser) expect(text string) ast.Token {
	tok := p.tok()
	if tok.text != text {
		p.error_at(tok, 'expected "${text}", found "${tok.str()}"')
	}
	p.pos++
	return tok
}

// is_end reports whether the cursor is at the end of an initializer list, which is
// either `}` or `,}` because a trailing comma is allowed.
fn (p &Parser) is_end() bool {
	return p.at('}') || (p.at(',') && p.tok_at(1).text == '}')
}

fn (mut p Parser) consume_end() bool {
	if p.at('}') {
		p.pos++
		return true
	}
	if p.at(',') && p.tok_at(1).text == '}' {
		p.pos += 2
		return true
	}
	return false
}

// --- diagnostics ---

// error_at records a diagnostic at a token.
//
// The message is prefixed `tcc:` rather than `fcc:` because that is what V's
// driver looks for: `v3_is_tcc_compilation_failure` treats any output line
// starting with `tcc:` as a compiler failure, and a compiler that reported errors
// in a format V does not recognise would make V fall back to `cc` instead of
// reporting what went wrong. See D22.
fn (mut p Parser) error_at(tok ast.Token, msg string) {
	if p.quiet > 0 {
		return
	}
	p.errors << p.render(tok, msg, '')
}

// error_at_help records a diagnostic with a `help:` follow-up, for the errors
// whose fix is known — a missing `;`, a mistyped suffix. Most call sites use
// `error_at`: a help that guesses is worse than none, so only patterns with a
// single plausible fix get one.
fn (mut p Parser) error_at_help(tok ast.Token, msg string, help string) {
	if p.quiet > 0 {
		return
	}
	p.errors << p.render(tok, msg, help)
}

// render builds the full diagnostic text: the terse first line, byte-identical
// to what this compiler always emitted (`tcc: file:line: message`, which is
// what V's driver keys on), followed by the V-style source block and the
// macro-expansion notes, when there is source to show. The column rides along
// only when the token has one — a synthesized location reports none, and
// printing `:0:` for it would be a lie about precision.
fn (mut p Parser) render(tok ast.Token, msg string, help string) string {
	mut s := 'tcc: ${p.token_file(tok)}:${tok.line.disp_line}'
	if tok.line.disp_col >= 1 {
		s += ':${tok.line.disp_col}'
	}
	s += ': ${msg}'
	s += diag_block(tok)
	if help != '' {
		s += '\n     = help: ${help}'
	}
	s += diag_notes(tok)
	return s
}

// token_file names the file a token came from, falling back to the translation unit's
// own name.
//
// A token stamped with a file is one that was read out of a header, and naming the header
// is the whole point: `time.h:241` and `time.h:234` are where the two errors are, while
// `dg.c:241` points at a file that does not have 241 lines. gcc names the header, and so
// does tcc.
//
// The fallback rather than an empty name, because a synthesized token — the parser builds
// some while speculating — has no file of its own and still has to be reported somewhere.
fn (p &Parser) token_file(tok ast.Token) string {
	if fl := tok.line.file {
		return fl.name
	}
	return p.path
}

// error_here records a diagnostic at the cursor.
fn (mut p Parser) error_here(msg string) {
	p.error_at(p.tok(), msg)
}

// warn_at records a diagnostic that does not prevent compilation.
//
// It has its own list, and that is the whole point: `errors` is what the driver counts
// to decide the exit code, so a warning folded into it would refuse a program both tcc
// and gcc accept. `time.h` calls `_gmtime64_s` having declared only `_gmtime64`, tcc
// prints a warning and exits 0, and gcc treats it as gnu11's implicit-declaration
// warning — while this used to fail the translation unit.
//
// The `warning:` spelling is what tcc and gcc both use, and it is also what V's driver
// looks for when deciding a warning is not a failure.
fn (mut p Parser) warn_at(tok ast.Token, msg string) {
	if p.quiet > 0 {
		return
	}
	p.warnings << p.render_warn(tok, msg)
}

// render_warn builds a warning the same way `render` builds an error, with the
// `warning:` spelling tcc and gcc both use — and V's driver looks for when
// deciding a warning is not a failure.
fn (mut p Parser) render_warn(tok ast.Token, msg string) string {
	mut s := 'tcc: ${p.token_file(tok)}:${tok.line.disp_line}'
	if tok.line.disp_col >= 1 {
		s += ':${tok.line.disp_col}'
	}
	s += ': warning: ${msg}'
	s += diag_block(tok)
	s += diag_notes(tok)
	return s
}

// --- scopes ---

fn (mut p Parser) enter_scope() {
	p.scopes << Scope{
		vars: map[string]&VarScope{}
		tags: map[string]&ast.Type{}
	}
}

fn (mut p Parser) leave_scope() {
	if p.scopes.len > 1 {
		p.scopes.delete(p.scopes.len - 1)
	}
}

// push_scope binds a name in the current block.
fn (mut p Parser) push_scope(name string) &VarScope {
	sc := &VarScope{ name: name }
	p.scopes[p.scopes.len - 1].vars[name] = sc
	return sc
}

// push_tag_scope binds a struct, union or enum tag in the current block.
fn (mut p Parser) push_tag_scope(name string, ty &ast.Type) {
	p.scopes[p.scopes.len - 1].tags[name] = ty
}

// find_var looks a name up through the block chain.
fn (p &Parser) find_var(name string) ?&VarScope {
	for i := p.scopes.len - 1; i >= 0; i-- {
		if sc := p.scopes[i].vars[name] {
			// A missing map entry reads as a nil pointer, and handing that back inside
			// an option would make is_typename true for a name that was never declared.
			if sc != unsafe { nil } {
				return sc
			}
		}
	}
	return none
}

// find_tag looks a tag up through the block chain.
fn (p &Parser) find_tag(name string) ?&ast.Type {
	for i := p.scopes.len - 1; i >= 0; i-- {
		if ty := p.scopes[i].tags[name] {
			return ty
		}
	}
	return none
}

// find_typedef returns the type a name is a typedef for, or none.
fn (p &Parser) find_typedef(tok ast.Token) ?&ast.Type {
	if tok.kind != .ident {
		return none
	}
	sc := p.find_var(tok.text) or { return none }
	return sc.type_def
}

// find_func returns the file-scope function with this name.
fn (p &Parser) find_func(name string) ?&ast.Obj {
	if p.scopes.len == 0 {
		return none
	}
	sc := p.scopes[0].vars[name] or { return none }
	if sc.obj != unsafe { nil } && sc.obj.is_function {
		return sc.obj
	}
	return none
}

// --- objects ---

// new_obj creates an object and binds its name in the current block.
fn (mut p Parser) new_obj(name string, ty &ast.Type, line int) &ast.Obj {
	obj := &ast.Obj{
		name:  name
		ty:    ty
		align: ty.align
		line:  line
	}
	if name != '' {
		p.push_scope(name).obj = obj
	}
	return obj
}

fn (mut p Parser) new_lvar(name string, ty &ast.Type, line int) &ast.Obj {
	mut obj := p.new_obj(name, ty, line)
	obj.is_local = true
	p.locals << obj
	return obj
}

fn (mut p Parser) new_gvar(name string, ty &ast.Type, line int) &ast.Obj {
	mut obj := p.new_obj(name, ty, line)
	obj.is_static = true
	obj.is_definition = true
	p.globals << obj
	return obj
}

// new_unique_name returns a name no other object has.
//
// The spelling matches chibicc's `.L..N` so that a `-S` dump can be compared with
// one, and because a dot cannot begin a C identifier, so a compiler-generated name
// can never collide with a user's.
fn (mut p Parser) new_unique_name() string {
	p.counter++
	return '.L..${p.counter}'
}

// new_anon_gvar creates a global with a generated name, which is what a string
// literal and a compound literal both need.
fn (mut p Parser) new_anon_gvar(ty &ast.Type, line int) &ast.Obj {
	return p.new_gvar(p.new_unique_name(), ty, line)
}

// --- nodes ---

fn (p &Parser) new_node(kind ast.NodeKind, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: kind
		tok:  tok
	}
}

fn (p &Parser) new_binary(kind ast.NodeKind, lhs &ast.Node, rhs &ast.Node,
	tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: kind
		tok:  tok
		lhs:  lhs
		rhs:  rhs
	}
}

fn (p &Parser) new_unary(kind ast.NodeKind, expr &ast.Node, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: kind
		tok:  tok
		lhs:  expr
	}
}

// new_num makes an integer literal node. Its type is left unset so that add_type
// gives it the type its spelling implies, which is not always int.
fn (p &Parser) new_num(val i64, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: .num
		tok:  tok
		num:  val
	}
}

// new_size_t makes the node `sizeof` and `_Alignof` return.
//
// It is an unsigned long long rather than an unsigned long because on this target
// `size_t` is 8 bytes while `long` is 4 — measured, not assumed. chibicc returns
// an unsigned long, which is right for System V and wrong here.
fn (p &Parser) new_size_t(val i64, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: .num
		tok:  tok
		num:  val
		ty:   ty_size_t
	}
}

fn (p &Parser) new_var_node(obj &ast.Obj, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: .var_ref
		tok:  tok
		var:  obj
	}
}

// new_alloca makes the call that allocates a variable-length array.
//
// It is built in vcc rather than emitted as a call to `alloca` because that keeps
// the runtime helper out of the phase 2 backend's way; the backend decides how to
// allocate.
//
// `ty` is deliberately left unset: `add_type` returns immediately on a node that
// already has one, so setting it here would leave the size argument with no type and
// the backend would read a null `Type` when it loaded it.
fn (mut p Parser) new_alloca(sz &ast.Node, tok ast.Token) &ast.Node {
	ty := func_type(pointer_to(ty_void))
	return &ast.Node{
		kind:    .funcall
		tok:     tok
		lhs:     p.new_var_node(p.builtin_alloca, tok)
		func_ty: ty
		args:    [&sz]
	}
}

// skip_balanced consumes a bracketed group, given its opening and closing spellings.
// An unterminated group stops at end of input rather than running off the end.
fn (mut p Parser) skip_balanced(open string, close string) {
	if !p.at(open) {
		return
	}
	mut depth := 0
	for p.tok().kind != .eof {
		if p.at(open) {
			depth++
		} else if p.at(close) {
			depth--
			if depth == 0 {
				p.pos++
				return
			}
		}
		p.pos++
	}
	p.error_here('unterminated ${open} group')
}

// skip_one_attribute consumes one attribute and its optional argument.
//
// The attributes vcc does not act on are consumed rather than rejected, because
// V's generated C carries several of them (`constructor`, `naked`,
// `visibility("default")`) and refusing them would make vcc unable to compile
// V's own output.
fn (mut p Parser) skip_one_attribute() {
	p.next()
	if p.at('(') {
		p.skip_balanced('(', ')')
	}
}

// attribute_list parses any number of `__attribute__((...))` groups and returns the
// alignment the last one asked for, or 0 for none.
//
// Two of them change the layout and so are honoured: `packed`, which is
// `#pragma pack(1)` spelled as an attribute, and `aligned(N)`. chibicc honours the
// same two. The rest are read and discarded, and that is a deliberate difference:
// chibicc reports "unknown attribute" for anything else, which would reject every
// function V marks `__attribute__((constructor))`.
fn (mut p Parser) attribute_list(ty ?&ast.Type) int {
	mut align := 0
	for p.at('__attribute__') || p.at('__attribute') {
		p.pos++
		p.expect('(')
		p.expect('(')
		for !p.at(')') {
			if p.consume(',') {
				continue
			}
			if p.at('packed') || p.at('__packed__') {
				if mut t := ty {
					t.pack = 1
				}
				p.pos++
				continue
			}
			if p.at('aligned') || p.at('__aligned__') {
				p.pos++
				p.expect('(')
				align = int(p.const_expr())
				p.expect(')')
				continue
			}
			p.skip_one_attribute()
		}
		p.expect(')')
		p.expect(')')
	}
	return align
}

// pack_at returns the `#pragma pack` value in effect at a line, or 0 when none is.
//
// The preprocessor sees `#pragma pack` and the layout code needs it, but the parser
// is not the preprocessor's caller in a way that lets it hold preprocessor state.
// Recording where each pragma took effect and asking by line number is enough,
// because a pragma is always on an earlier line than the struct it governs.
fn (p &Parser) pack_at(line int) int {
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

// --- declaration specifiers ---

// The type specifiers are counted rather than matched, so that the order does not
// matter and `unsigned long long int` falls out of the same table as `long long`.
// Each constant is one bit of the counter's high half; `ts_other` marks that a
// struct, union, enum, typedef or `typeof` supplied the type instead.
const ts_void = 1 << 0
const ts_bool = 1 << 2
const ts_char = 1 << 4
const ts_short = 1 << 6
const ts_int = 1 << 8
const ts_long = 1 << 10
const ts_float = 1 << 12
const ts_double = 1 << 14
const ts_other = 1 << 16
const ts_signed = 1 << 17
const ts_unsigned = 1 << 18

// declspec parses a declaration's specifiers and returns the type they name.
//
//	 declspec = ("void" | "_Bool" | "char" | "short" | "int" | "long"
//	            | "typedef" | "static" | "extern" | "inline"
//	            | "_Thread_local" | "signed" | "unsigned"
//	            | struct-decl | union-decl | typedef-name
//	            | enum-specifier | typeof-specifier
//	            | "const" | "volatile" | "auto" | "register" | "restrict"
//	            | "_Noreturn")+
//
// The order of the type specifiers is free: `int long static` means the same as
// `static long int`. Something like `char int` is not valid, and the counter is
// what rejects it: the combination matches no arm.
fn (mut p Parser) declspec(attr ?&VarAttr) &ast.Type {
	mut ty := ty_int
	mut counter := 0
	mut atomic_spec := false

	// mingw's headers write attributes *between* the specifiers as well as before them:
	// `extern` on one line, `__attribute__((format(gnu_printf, 3, 0)))` on the next, and
	// the type on the third. Consuming them only ahead of `declspec` left this loop
	// exiting at the first one, so the declarator was parsed from `__attribute__` and
	// the declaration was reported as `variable name omitted`.
	for p.is_typename() || p.at('__attribute__') || p.at('__attribute') {
		// An attribute in the middle of a specifier list can only be a type attribute,
		// because no declarator has been read yet. `none` for the type name is what the
		// standalone call sites pass.
		if p.at('__attribute__') || p.at('__attribute') {
			p.attribute_list(none)
			continue
		}
		tok := p.tok()

		// GNU's spellings of `inline`. `__CRT_INLINE` expands to `static __inline__`, so
		// without these every inline definition in mingw's `string.h` and `wchar.h` parses
		// as a declaration with no name.
		if tok.text in gnu_inline_keywords {
			if mut a := attr {
				a.is_inline = true
				if a.is_typedef && (int(a.is_static) + int(a.is_extern) +
					int(a.is_inline) + int(a.is_tls)) > 1 {
					p.error_at(tok, 'typedef may not be used together with static, extern, inline, __thread or _Thread_local')
				}
			} else {
				p.error_at(tok, 'storage class specifier is not allowed in this context')
			}
			p.pos++
			continue
		}

		if tok.text == 'typedef' || tok.text == 'static' || tok.text == 'extern'
			|| tok.text == 'inline' || tok.text == '_Thread_local'
			|| tok.text == '__thread' {
			if mut a := attr {
				if tok.text == 'typedef' {
					a.is_typedef = true
				} else if tok.text == 'static' {
					a.is_static = true
				} else if tok.text == 'extern' {
					a.is_extern = true
				} else if tok.text == 'inline' {
					a.is_inline = true
				} else {
					a.is_tls = true
				}
				if a.is_typedef && (int(a.is_static) + int(a.is_extern) +
					int(a.is_inline) + int(a.is_tls)) > 1 {
					p.error_at(tok, 'typedef may not be used together with static, extern, inline, __thread or _Thread_local')
				}
			} else {
				p.error_at(tok, 'storage class specifier is not allowed in this context')
			}
			p.pos++
			continue
		}

		// Recognised and ignored: they qualify the type without changing it.
		//
		// The calling-convention specifiers belong here too, and ignoring them is right
		// on this target: the Microsoft x64 ABI has one convention, so none of them
		// changes how an argument is passed. See `calling_convention_keywords`.
		if p.consume('const') || p.consume('volatile') || p.consume('auto')
			|| p.consume('register') || p.consume('restrict') || p.consume('__restrict')
			|| p.consume('__restrict__') || p.consume('_Noreturn')
			|| p.consume('__extension__')
			|| tok.text in calling_convention_keywords {
			if tok.text in calling_convention_keywords {
				p.pos++
			}
			continue
		}

		if p.at('_Atomic') {
			p.pos++
			atomic_spec = true
			if p.consume('(') {
				ty = p.typename()
				p.expect(')')
			}
			continue
		}

		// [C11 7.16] `va_list` is `char *` on this target — measured, not assumed:
		// mingw gcc and tcc both report `sizeof(va_list) == 8`, and `src/ast/abi.v`
		// records what the eight bytes are. It is the type every `<stdarg.h>` here
		// reduces to, so it is a type specifier rather than a typedef registered per
		// translation unit: a program that includes no header and spells the builtin
		// directly gets the same type.
		if tok.text == '__builtin_va_list' {
			p.pos++
			ty = ty_va_list()
			counter++
			continue
		}

		if p.at('_Alignas') {
			p.pos++
			p.expect('(')
			mut align := 0
			if p.is_typename() {
				align = p.typename().align
			} else {
				align = int(p.const_expr())
			}
			if mut a := attr {
				a.align = align
			} else {
				p.error_at(tok, '_Alignas is not allowed in this context')
			}
			p.expect(')')
			continue
		}

		// A type the user defined supplies the whole type, so it cannot be combined
		// with a built-in specifier.
		user_ty := p.find_typedef(tok)
		if tok.text == 'struct' || tok.text == 'union' || tok.text == 'enum'
			|| tok.text == 'typeof' || tok.text == '__typeof__' || user_ty != none {
			if counter != 0 {
				break
			}
			if tok.text == 'struct' {
				p.pos++
				ty = p.struct_union_decl(.struct_)
			} else if tok.text == 'union' {
				p.pos++
				ty = p.struct_union_decl(.union_)
			} else if tok.text == 'enum' {
				p.pos++
				ty = p.enum_specifier()
			} else if tok.text == 'typeof' || tok.text == '__typeof__' {
				p.pos++
				ty = p.typeof_specifier()
			} else {
				ty = user_ty or { ty_int }
				p.pos++
			}
			counter += ts_other
			continue
		}

		if tok.text == 'void' {
			counter += ts_void
		} else if tok.text == '_Bool' {
			counter += ts_bool
		} else if tok.text == 'char' {
			counter += ts_char
		} else if tok.text == 'short' {
			counter += ts_short
		} else if tok.text == 'int' {
			counter += ts_int
		} else if tok.text == 'long' {
			counter += ts_long
		} else if tok.text == 'float' {
			counter += ts_float
		} else if tok.text == 'double' {
			counter += ts_double
		} else if tok.text == 'signed' {
			counter |= ts_signed
		} else if tok.text == 'unsigned' {
			counter |= ts_unsigned
		} else {
			p.error_at(tok, 'unexpected type specifier "${tok.text}"')
			p.pos++
			continue
		}

		ty = match counter {
			ts_void { ty_void }
			ts_bool { ty_bool }
			ts_char, ts_signed + ts_char { ty_char }
			ts_unsigned + ts_char { ty_uchar }
			ts_short, ts_short + ts_int, ts_signed + ts_short, ts_signed + ts_short + ts_int {
				ty_short
			}
			ts_unsigned + ts_short, ts_unsigned + ts_short + ts_int { ty_ushort }
			ts_int, ts_signed, ts_signed + ts_int { ty_int }
			ts_unsigned, ts_unsigned + ts_int { ty_uint }
			ts_long, ts_long + ts_int, ts_signed + ts_long, ts_signed + ts_long + ts_int {
				ty_long
			}
			// `long long` is a distinct type from `long` on this target: 8 bytes
			// against 4. Collapsing the two would mis-size every `long long` in
			// V's generated C and every 64-bit constant.
			ts_long + ts_long, ts_long + ts_long + ts_int, ts_signed + ts_long + ts_long,
			ts_signed + ts_long + ts_long + ts_int {
				ty_llong
			}
			ts_unsigned + ts_long, ts_unsigned + ts_long + ts_int { ty_ulong }
			ts_unsigned + ts_long + ts_long, ts_unsigned + ts_long + ts_long + ts_int {
				ty_ullong
			}
			ts_float { ty_float }
			ts_double { ty_double }
			ts_long + ts_double { ty_ldouble }
			else {
				p.error_at(tok, 'invalid combination of type specifiers')
				ty_int
			}
		}
		p.pos++
	}

	if atomic_spec {
		ty = copy_type(ty)
		ty.is_atomic = true
	}
	return ty
}

// is_typename reports whether the token at the cursor can begin a type.
//
// The answer decides how a declaration is read, so it must not consume anything.
// A typedef name counts, which is why it is a scope lookup rather than a keyword
// test.
fn (p &Parser) is_typename() bool {
	tok := p.tok()
	if tok.kind == .ident {
		// A calling-convention or GNU-`inline` specifier names no type, but each is a
		// declaration specifier and `declspec` has to see it to act on it. See
		// `calling_convention_keywords` and `gnu_inline_keywords`.
		return p.find_typedef(tok) != none || tok.text in calling_convention_keywords
			|| tok.text in gnu_inline_keywords
	}
	if tok.kind != .keyword {
		return false
	}
	// A folded alias keyword keeps its own spelling as its text, so `__inline` and
	// `__inline__` arrive here as `.keyword` tokens whose text is *not* in
	// `type_specifier_keywords` — which is why they were rejected here even after the
	// `.ident` branch learned about them. Both lists are consulted in both branches.
	return tok.text in type_specifier_keywords || tok.text in gnu_inline_keywords
		|| tok.text in calling_convention_keywords
}

// gnu_inline_keywords are GNU's spellings of `inline`, which mingw's headers use
// everywhere — `__CRT_INLINE` is `static __inline__`, so every inline definition in
// `string.h` and `wchar.h` is written with one.
//
// They are storage-class specifiers that mean exactly what `inline` means, and treating
// them as anything else makes a whole function definition parse as a declaration with no
// name: `__inline int f(int x) { return x; }` was reported as `variable name omitted`.
// gcc accepts all four spellings.
//
// Listed rather than added to the tokenizer's keyword table, so a program with its own
// identifier called `inline` still compiles.
const gnu_inline_keywords = [
	'__inline'
	'__inline__'
	'__forceinline'
]

// calling_convention_keywords are the Microsoft and GNU calling-convention specifiers,
// which mingw's headers write on almost every declaration: `int __cdecl abs(int)`,
// `double __stdcall _hypot(double, double)`, `LRESULT CALLBACK WndProc(...)`.
//
// They are ignored rather than implemented, and ignoring them is correct on this target
// rather than a shortcut: the Microsoft x64 ABI has exactly one calling convention, so
// `__cdecl`, `__stdcall`, `__fastcall` and `WINAPI` all mean the same thing and none of
// them changes how an argument is passed. `src/ast/abi.v` records the measurement.
//
// They are listed here rather than added to the tokenizer's keyword table for the reason
// `type_specifier_keywords` gives: a keyword cannot be spelled as an identifier, and a
// program that has its own variable called `cdecl` would stop compiling.
const calling_convention_keywords = [
	'__cdecl'
	'__stdcall'
	'__fastcall'
	'__thiscall'
	'__clrcall'
	'__vectorcall'
	'__cdecl__'
	'__stdcall__'
	'__fastcall__'
	'__thiscall__'
	// mingw's own aliases, spelled without leading underscores because they came from
	// windows.h. They expand to `__stdcall` through its headers, so a translation unit
	// that does not include windows.h still has to accept them.
	'WINAPI'
	'CALLBACK'
	'APIENTRY'
	'APIPRIVATE'
	'NTAPI'
]

// type_specifier_keywords are the keywords that can begin a type. `__thread` is not
// a C keyword but is a GNU one, and it is listed here rather than added to the
// lexer because adding a keyword would make it unspellable as an identifier.
const type_specifier_keywords = [
	'void'
	'_Bool'
	'char'
	'short'
	'int'
	'long'
	'struct'
	'union'
	'typedef'
	'enum'
	'static'
	'extern'
	'_Alignas'
	'signed'
	'unsigned'
	'const'
	'volatile'
	'auto'
	'register'
	'restrict'
	'__restrict'
	'__restrict__'
	'_Noreturn'
	'float'
	'double'
	'typeof'
	'__typeof__'
	'inline'
	'_Thread_local'
	'__thread'
	'_Atomic'
	'__extension__'
	// `__builtin_va_list` is the whole of the type system this target's `<stdarg.h>`
	// has: `typedef __builtin_va_list va_list;`. It has to answer `is_typename` or the
	// typedef never parses, and `declspec` turns it into a pointer to char.
	'__builtin_va_list',
]

// --- declarators ---
//
// A declarator is read as a *shape* first and turned into a type afterwards.
//
// chibicc reads one and returns a type directly, which means it has to parse a nested
// declarator twice: once against a throwaway type to find where it ends, and once
// against the real type once the suffixes are known. That trick needs the cursor to be
// saved and restored around the first pass, and `int (*fp)(void)` — where the first
// pass and the second pass disagree about where the group ends — took the parser into
// unbounded recursion.
//
// Reading the shape and building the type afterwards has no such hazard: the shape is a
// small tree, it is read once, and building it cannot loop.

// Decl is the shape of one declarator.
//
// The order the fields are applied in is the order C reads a declarator right to left:
// a suffix binds tighter than a `*`, and a parenthesised group is read last.
struct Decl {
mut:
	// ptrs is the number of `*` before the name.
	ptrs int
	// nested is a declarator inside parentheses, as in `(*fp)`.
	nested ?&Decl
	name   string
	line   int
	// suffixes are the `(` and `[` groups that follow, in source order.
	suffixes []Suffix
}

// Suffix is one `(` or `[` group of a declarator.
//
// A function suffix keeps its parameter types but not its return type: the return type
// is whatever the declarator ends up modifying, which is only known when the shape is
// built.
struct Suffix {
mut:
	is_func  bool
	func_ty  &ast.Type = unsafe { nil }
	is_array bool
	// array_len is the element count, or -1 when it is not known from the source.
	array_len int = -1
	// vla_len is the element count as an expression, for a variable-length array.
	vla_len &ast.Node = unsafe { nil }
}

// parse_decl_shape reads one declarator's shape.
//
//	declarator = pointers ("(" declarator ")")? ident? type-suffix
//
// A `(` immediately after the pointers is a group only when a declarator follows it;
// otherwise it is a parameter list, which is what distinguishes `int (*fp)(void)` from
// `int (*)(void)`.
fn (mut p Parser) parse_decl_shape(allow_name bool) &Decl {
	mut d := &Decl{
		ptrs:     0
		nested:   none
		name:     ''
		line:     p.tok().line.disp_line
		suffixes: []Suffix{}
	}
	for p.consume('*') {
		d.ptrs++
		for p.at('const') || p.at('volatile') || p.at('restrict') || p.at('__restrict')
			|| p.at('__restrict__') {
			p.pos++
		}
	}

	if p.at('(') && p.starts_declarator_at(1) {
		p.pos++
		d.nested = p.parse_decl_shape(allow_name)
		p.expect(')')
	} else if allow_name && p.tok().kind == .ident {
		d.name = p.tok().text
		d.line = p.tok().line.disp_line
		p.pos++
	}

	for p.at('(') || p.at('[') {
		d.suffixes << p.parse_suffix()
	}
	return d
}

// starts_declarator_at reports whether a declarator begins n tokens ahead.
//
// A declarator begins with `*`, with a group, or with a name. A parameter list begins
// with a type or with `void`, which is the whole of the distinction.
fn (mut p Parser) starts_declarator_at(n int) bool {
	tok := p.tok_at(n)
	if tok.text == '*' || tok.text == '(' {
		return true
	}
	// A name that is not a type name can only be a declarator's name. An abstract
	// declarator has no name, so `(` after `(` is the only group form that matters.
	return tok.kind == .ident && !p.is_typename_at(n)
}

// parse_suffix reads one `(` or `[` group.
fn (mut p Parser) parse_suffix() Suffix {
	if p.at('(') {
		p.pos++
		mut s := Suffix{
			is_func: true
			func_ty: p.parse_func_params()
		}
		p.expect(')')
		return s
	}
	p.expect('[')
	mut s := Suffix{
		is_array:  true
		array_len: -1
	}
	// `[static]` and `[restrict]` are allowed on a parameter's array declarator.
	for p.at('static') || p.at('restrict') || p.at('__restrict') || p.at('__restrict__') {
		p.pos++
	}
	if !p.at(']') {
		mut len := p.const_expr_node()
		if is_const_expr(mut len) {
			s.array_len = int(eval(mut len))
		} else {
			// A length that is not a constant makes the type a variable-length array,
			// whose extent is only known at run time.
			s.vla_len = len
		}
	}
	// The bracket is closed here and nowhere else, so `a[]`, `a[3]` and `a[n]` all
	// consume exactly one `]`.
	p.expect(']')
	return s
}

// build_decl turns a declarator's shape into the type it modifies.
//
// A suffix binds tighter than a `*`, and a parenthesised group is read last, so the
// order the parts are applied in is what distinguishes `int *a[10]` (an array of
// pointers) from `int (*a)[10]` (a pointer to an array).
//
// Without a group the `*`s come first, because `*a[10]` is ten of them. With a group
// the suffixes come first, because in `(*a)[10]` the `*` is inside the group and the
// `[10]` applies to the group as a whole.
//
// **The suffixes apply right to left.** `int a[3][5]` is an array of three, each an
// array of five, so the `[5]` is applied to `int` first and the `[3]` to the result. They
// were applied in source order, which builds `array(array(int, 3), 5)` instead.
//
// The two differ in a total size and in nothing else that a self-consistent program
// looks at, which is why this survived: both are 3*5*4, and `a[i][j]` reads and writes
// through the same reversed shape, so every value came back right. Two things noticed
// it. `sizeof(*a)` is 12 rather than 20. And the *stride* is 12, so `&a[1]` is twelve
// bytes past `&a[0]` where it must be twenty — which matters the moment anything whose
// layout is not this compiler's agrees about where a row is: `int (*pa)[5] = a`, then
// `pa`, or a C library. Measured, tcc against this:
//
//	                 tcc    vcc
//	&a[1] - &a[0]      20    12
//	int b[2][3][4], &b[1] - &b[0]   48    24
//	                &b[0][1] - &b[0][0]  16     8
fn (mut p Parser) build_decl(base &ast.Type, d &Decl) &ast.Type {
	mut t := base
	if nested := d.nested {
		for i := d.suffixes.len - 1; i >= 0; i-- {
			t = p.apply_suffix(t, d.suffixes[i])
		}
		for _ in 0 .. d.ptrs {
			t = pointer_to(t)
		}
		return p.build_decl(t, nested)
	}
	for _ in 0 .. d.ptrs {
		t = pointer_to(t)
	}
	for i := d.suffixes.len - 1; i >= 0; i-- {
		t = p.apply_suffix(t, d.suffixes[i])
	}
	return t
}

// apply_suffix applies one `(` or `[` group to a type.
fn (p &Parser) apply_suffix(base &ast.Type, s Suffix) &ast.Type {
	if s.is_func {
		// The parameter types were parsed already; only the return type is still open.
		mut ft := copy_type(s.func_ty)
		ft.ret_type = base
		return ft
	}
	if s.vla_len != unsafe { nil } {
		return vla_of(base, s.vla_len)
	}
	return array_of(base, s.array_len)
}

// declarator parses a declarator and returns the type it modifies, with the declared
// name attached.
//
// The name goes onto a *copy* of the type: the type may be one of the shared basic
// types, and writing a name onto one of those is a runtime panic rather than a silent
// mistake.
// decl_name returns the name a declarator's shape carries.
//
// The name is not always on the outermost part: in `int (*fp)(void)` the shape's outer
// part is the group and the name belongs to `*fp` inside it, so the name is found by
// descending into the group.
fn decl_name(d &Decl) (string, int) {
	if d.name != '' {
		return d.name, d.line
	}
	if nested := d.nested {
		return decl_name(nested)
	}
	return '', 0
}

fn (mut p Parser) declarator(ty &ast.Type) &ast.Type {
	d := p.parse_decl_shape(true)
	mut built := p.build_decl(ty, d)
	built = copy_type(built)
	built.name, built.name_line = decl_name(d)
	return built
}

// abstract_declarator is a declarator without a name, as used by a cast or `sizeof(T)`.
fn (mut p Parser) abstract_declarator(ty &ast.Type) &ast.Type {
	d := p.parse_decl_shape(false)
	return p.build_decl(ty, d)
}

// typename parses `declspec abstract-declarator`.
fn (mut p Parser) typename() &ast.Type {
	ty := p.declspec(none)
	return p.abstract_declarator(ty)
}

// parse_func_params parses a parameter list and returns a function type whose return
// type is not yet set.
//
//	func-params = ("void" | param ("," param)* ("," "...")?)? ")"
//	param       = declspec declarator
//
// `(void)` is a function of no parameters and not a variadic one; an empty list *is*
// variadic in C, which is why the two spellings have to be told apart.
fn (mut p Parser) parse_func_params() &ast.Type {
	if p.at('void') && p.tok_at(1).text == ')' {
		// Only oid is consumed. The closing paren belongs to parse_suffix, which
		// opened the group, so that there is exactly one place that closes it.
		p.pos++
		mut ft := func_type(unsafe { nil })
		ft.params = []&ast.Type{}
		ft.is_variadic = false
		return ft
	}

	mut params := []&ast.Type{}
	mut variadic := false

	for !p.at(')') {
		if params.len > 0 {
			p.expect(',')
		}
		if p.at('...') {
			// The closing paren is left for the caller, so that a parameter list is
			// consumed by exactly one code path.
			variadic = true
			p.pos++
			break
		}
		if p.tok().kind == .eof {
			break
		}
		mut pty := p.declspec(none)
		pty = p.declarator(pty)
		name := pty.name
		line := pty.name_line

		// An array parameter is a pointer to its element, and a function parameter is a
		// pointer to the function. This is the only place C makes those adjustments,
		// which is why `int argv[]` and `int (*argv)[]` mean the same thing.
		if pty.kind == .array || pty.kind == .vla {
			mut adj := pointer_to(pty.base)
			adj = copy_type(adj)
			adj.name = name
			adj.name_line = line
			pty = adj
		} else if pty.kind == .func {
			mut adj := pointer_to(pty)
			adj = copy_type(adj)
			adj.name = name
			adj.name_line = line
			pty = adj
		}
		params << pty
	}

	if params.len == 0 {
		variadic = true
	}
	mut ft := func_type(unsafe { nil })
	ft.params = params
	ft.is_variadic = variadic
	return ft
}

// --- enum ---

// enum_specifier parses an enumeration.
//
//	enum-specifier = ident? "{" enum-list? "}" | ident ("{" enum-list? "}")?
//	enum-list      = ident ("=" num)? ("," ident ("=" num)?)* ","?
fn (mut p Parser) enum_specifier() &ast.Type {
	mut ty := enum_type()

	mut tag := ''
	if p.tok().kind == .ident {
		tag = p.tok().text
		p.pos++
	}
	ty.tag = tag

	if tag != '' && !p.at('{') {
		found := p.find_tag(tag) or {
			p.error_here('unknown enum type "${tag}"')
			ty
		}
		if found.kind != .enum_ {
			p.error_here('"${tag}" is not an enum tag')
		}
		return found
	}

	p.expect('{')
	mut next := i64(0)
	mut seen := 0
	for !p.consume_end() {
		if p.tok().kind == .eof {
			break
		}
		if seen > 0 {
			p.expect(',')
			if p.consume_end() {
				break
			}
		}
		seen++
		tok := p.tok()
		if tok.kind != .ident {
			p.error_here('expected an enumeration constant')
			p.pos++
			continue
		}
		name := tok.text
		p.pos++
		if p.consume('=') {
			next = p.const_expr()
		}
		mut sc := p.push_scope(name)
		sc.enum_ty = ty
		sc.enum_val = next
		next++
	}
	if tag != '' {
		p.push_tag_scope(tag, ty)
	}
	return ty
}

// typeof_specifier parses `(type)` or `(expression)` and returns that type.
fn (mut p Parser) typeof_specifier() &ast.Type {
	p.expect('(')
	if p.is_typename() {
		ty := p.typename()
		p.expect(')')
		return ty
	}
	mut node := p.const_expr_node()
	add_type(mut node)
	p.expect(')')
	return node.ty
}

// --- struct and union ---

// struct_union_decl parses a struct or union declaration and computes its layout.
//
//	struct-union-decl = attribute? ident? ("{" struct-members)?
//
// The layout algorithm is chibicc's, and its output was checked against tcc's by
// writing known values into each struct and comparing the raw bytes: five bitfield
// layouts, a packed struct, a nested struct, a union and a long/double pair all
// agree byte for byte.
fn (mut p Parser) struct_union_decl(kind ast.TypeKind) &ast.Type {
	mut ty := if kind == .struct_ { struct_type() } else { union_type() }
	mut align := p.attribute_list(ty)
	if align != 0 {
		ty.align = align
	}

	mut tag := ''
	if p.tok().kind == .ident {
		tag = p.tok().text
		p.pos++
	}
	ty.tag = tag

	// A tag used without a body names a type declared elsewhere, or completes one
	// declared earlier. Size -1 is what marks it incomplete.
	if tag != '' && !p.at('{') {
		if found := p.find_tag(tag) {
			return found
		}
		ty.size = -1
		p.push_tag_scope(tag, ty)
		return ty
	}

	p.expect('{')
	body_line := p.tok().line.disp_line
	p.struct_members(mut ty, body_line)
	p.attribute_list(ty)

	if tag != '' {
		// A redefinition overwrites the type the tag already names, rather than
		// binding the tag to a new one, so that a pointer to the tag made before the
		// definition sees the completed type too.
		if mut found := p.scopes[p.scopes.len - 1].tags[tag] {
			found.tag = tag
			found.kind = ty.kind
			found.size = ty.size
			found.align = ty.align
			found.members = ty.members
			found.is_flexible = ty.is_flexible
			found.pack = ty.pack
			return found
		}
		p.push_tag_scope(tag, ty)
	}
	return ty
}

// struct_members parses the body of a struct or union and lays it out.
//
// body_line is the line the body starts on, which is how `#pragma pack` is found:
// the pragma is always on an earlier line than the struct it governs.
fn (mut p Parser) struct_members(mut ty &ast.Type, body_line int) {
	mut members := []ast.Member{}

	for !p.at('}') {
		if p.tok().kind == .eof {
			p.error_here('unterminated struct definition')
			break
		}
		before := p.pos
		mut attr := VarAttr{}
		p.attribute_list(none)
		basety := p.declspec(&attr)
		p.attribute_list(none)

		// An anonymous struct or union member: the inner type's fields belong to the
		// outer struct's namespace. The MinGW headers use these, so they cannot be
		// deferred.
		if (basety.kind == .struct_ || basety.kind == .union_) && p.consume(';') {
			members << ast.Member{
				name:  ''
				ty:    basety
				align: if attr.align != 0 { attr.align } else { basety.align }
			}
			continue
		}

		mut first := true
		for !p.consume(';') {
			if p.tok().kind == .eof {
				break
			}
			if !first {
				p.expect(',')
			}
			first = false
			if p.at(';') || p.at('}') {
				continue
			}
			mty := p.declarator(basety)
			mut mem := ast.Member{
				name:  mty.name
				ty:    mty
				align: if attr.align != 0 { attr.align } else { mty.align }
			}
			if p.consume(':') {
				mem.is_bitfield = true
				mem.bit_width = int(p.const_expr())
			}
			members << mem
		}
		if p.pos == before {
			p.error_here('expected a member declaration')
			p.pos++
		}
	}
	p.expect('}')

	// A last member that is an array of unknown length is a flexible array member,
	// which behaves as an array of zero elements.
	if members.len > 0 {
		last := members.len - 1
		if members[last].ty.kind == .array && members[last].ty.array_len < 0 {
			members[last].ty = array_of(members[last].ty.base, 0)
			ty.is_flexible = true
		}
	}
	ty.members = members

	p.layout_struct(mut ty, body_line)
}

// layout_struct assigns member offsets and the type's own size and alignment.
//
// A bitfield is placed by bit position rather than by byte offset, and two rules
// decide where. A field that would straddle a boundary of its own storage unit
// starts a new one, and a zero-width field ends the current unit without starting a
// field of its own. A non-bitfield member is aligned to the lesser of its own
// requirement and the struct's packing.
fn (p &Parser) layout_struct(mut ty &ast.Type, body_line int) {
	if ty.kind == .union_ {
		p.layout_union(mut ty, body_line)
		return
	}
	mut pack := ty.pack
	if pack == 0 {
		pack = p.pack_at(body_line)
	}
	mut align := 1
	mut bits := 0
	for i, member in ty.members {
		mut mem := member
		mut eff := mem.align
		if pack > 0 && eff > pack {
			eff = pack
		}
		if mem.is_bitfield && mem.bit_width == 0 {
			// A zero-width bitfield is a padding directive: it rounds the current bit
			// position up to the next storage unit and contributes no field. Its offset is
			// recorded anyway, because that is where the padding landed and an initializer
			// walk needs to know it consumed nothing there.
			bits = align_to(bits, mem.ty.size * 8)
			mem.offset = bits / 8
			mem.bit_offset = 0
		} else if mem.is_bitfield {
			sz := mem.ty.size
			if bits / (sz * 8) != (bits + mem.bit_width - 1) / (sz * 8) {
				bits = align_to(bits, sz * 8)
			}
			// The offset is the start of the storage unit, which may be before the
			// first bit the field occupies; bit_offset says where in it the field is.
			mem.offset = align_down(bits / 8, sz)
			mem.bit_offset = bits % (sz * 8)
			bits += mem.bit_width
		} else {
			bits = align_to(bits, eff * 8)
			mem.offset = bits / 8
			bits += mem.ty.size * 8
		}
		if eff > align {
			align = eff
		}
		ty.members[i] = mem
	}
	if pack > 0 && align > pack {
		align = pack
	}
	// An explicit `__attribute__((aligned(N)))` raises the alignment beyond anything the
	// members imply, so the alignment is only ever raised here and never lowered.
	if align > ty.align {
		ty.align = align
	}
	ty.size = align_to(bits, ty.align * 8) / 8
}

// layout_union computes a union's size and alignment.
//
// Every member starts at zero, so only the largest size and the strictest alignment
// have to be found.
fn (p &Parser) layout_union(mut ty &ast.Type, body_line int) {
	mut pack := ty.pack
	if pack == 0 {
		pack = p.pack_at(body_line)
	}
	mut align := 1
	mut size := 0
	for mem in ty.members {
		mut eff := mem.align
		if pack > 0 && eff > pack {
			eff = pack
		}
		if eff > align {
			align = eff
		}
		if mem.ty.size > size {
			size = mem.ty.size
		}
	}
	if pack > 0 && align > pack {
		align = pack
	}
	if align > ty.align {
		ty.align = align
	}
	ty.size = align_to(size, ty.align)
}

// get_struct_member finds a member by name, looking through anonymous members.
//
// An anonymous struct or union contributes its own fields to the enclosing
// namespace, so `x.a` can reach a field declared in an unnamed inner struct.
fn (p &Parser) get_struct_member(ty &ast.Type, name string) ?int {
	for i, mem in ty.members {
		if mem.name == '' && (mem.ty.kind == .struct_ || mem.ty.kind == .union_) {
			if p.get_struct_member(mem.ty, name) != none {
				return i
			}
			continue
		}
		if mem.name == name {
			return i
		}
	}
	return none
}

// --- declarations ---

// declare_builtin_functions declares the functions the parser itself refers to.
//
// `alloca` is one of them: a variable-length array is translated into a call to it,
// which is the only way the front end ever mentions a function that no C source
// declared. It is declared as `void *alloca(int)` rather than with the real
// signature, because a VLA's byte size is what is passed.
fn (mut p Parser) declare_builtin_functions() {
	mut ty := func_type(pointer_to(ty_void))
	ty.params = [ty_int]
	// `new_obj` rather than `new_gvar`, because `alloca` is not part of the translation
	// unit: it is never declared in the C source and never referred to by name there,
	// only reached through `p.builtin_alloca`. Putting it in `globals` would make every
	// `globals[0]` in the parser's own tests an `alloca` that no C program declares.
	mut obj := p.new_obj('alloca', ty, 0)
	obj.is_function = true
	obj.is_definition = false
	obj.is_static = false
	p.builtin_alloca = obj
}

// translation_unit parses one whole file.
//
//	program = (typedef | function-definition | global-variable)*
fn (mut p Parser) translation_unit() {
	// `alloca` is the one function the front end invents rather than reads from the C
	// source, and it has to exist before any variable-length array is parsed. The guard
	// keeps a second file in the same Parser from creating a second `alloca` global.
	if p.builtin_alloca == unsafe { nil } {
		p.declare_builtin_functions()
	}
	for p.tok().kind != .eof {
		before := p.pos
		mut attr := VarAttr{}
		p.attribute_list(none)
		basety := p.declspec(&attr)

		if attr.is_typedef {
			p.parse_typedef(basety)
		} else if p.is_function() {
			p.function(basety, attr)
		} else {
			p.global_variable(basety, attr)
		}

		// Every branch above must have consumed something. One that did not would
		// spin here forever, so the fallback advances and reports rather than
		// trusting the next iteration to make progress.
		if p.pos == before {
			p.error_here('expected a declaration')
			p.pos++
		}
	}
}

// is_function reports whether the declaration at the cursor is a function.
//
// It parses the declarator against a throwaway type to find out, so it speculates:
// any diagnostic from that parse is dropped, or every function would report each of
// its own errors twice.
fn (mut p Parser) is_function() bool {
	if p.at(';') {
		return false
	}
	save := p.pos
	saved_errors := p.errors.len
	p.quiet++
	ty := p.declarator(struct_type())
	p.quiet--
	p.pos = save
	p.errors = p.errors[..saved_errors]
	return ty.kind == .func
}

// function parses a function definition or declaration.
//
// The body is not parsed in this slice: its token extent is recorded on the object
// so the next one can pick it up exactly, and the count is reported rather than
// being silently dropped.
fn (mut p Parser) function(basety &ast.Type, attr VarAttr) {
	ty := p.declarator(basety)
	if ty.name == '' {
		p.error_here('function name omitted')
		p.skip_to_decl_end()
		return
	}
	name := ty.name
	line := ty.name_line

	// Attributes may follow the declarator on a *declaration*, and mingw's headers write
	// them exactly there: `void __cdecl exit(int _Code) __MINGW_ATTRIB_NORETURN;` is
	// `void __cdecl exit(int _Code) __declspec(noreturn);`, and `__declspec(n)` is
	// `__attribute__((n))`. gcc accepts this form and so does tcc; reading the attribute
	// here is what keeps it from being parsed as a stray token after the declaration.
	//
	// `none` for the type name: the alignment a declarator attribute could ask for has no
	// place to go at this point, and the layout-altering attributes appear ahead of the
	// declarator, where `declspec` already consumes them.
	p.attribute_list(none)

	mut fn_obj := &ast.Obj{}
	if existing := p.find_func(name) {
		fn_obj = existing
		if fn_obj.is_definition && p.at('{') {
			p.error_here('redefinition of ${name}')
		}
		// [C11 6.2.2p7] is a constraint here, but only for declarations that establish
		// linkage the same way. A declaration carrying an `inline` specifier is the case the
		// standard carves out and every real library header relies on: `extern int f(int);`
		// followed by `static inline int f(int) { ... }` is how tcc's own headers spell a
		// definition that cannot be inlined at the call site.
		//
		// tcc accepts all three shapes, including a plain `static` after a non-static one, so
		// it does not implement the constraint at all. gcc rejects all three — it rejects
		// `stdio.h:259`, `tcc_libm.h:49` and `wchar.h:855` from this very include tree,
		// because they are tcc's headers and it is the stricter of the two. Exempting
		// `inline` is the line that keeps tcc's headers compiling while still reporting a
		// genuine linkage change.
		if !fn_obj.is_static && attr.is_static && !attr.is_inline {
			p.error_here('static declaration follows a non-static declaration: ${name}')
		}
		if p.at('{') {
			fn_obj.is_definition = true
			// A definition's own type is the authoritative one: a prior declaration may
			// have said `int f();`, and the parameters it actually has are the ones its
			// body can name. Leaving the old type in place would give the body the
			// declaration's unnamed parameters and make every one of them undefined.
			fn_obj.ty = ty
		}
	} else {
		fn_obj = p.new_gvar(name, ty, line)
		fn_obj.is_function = true
		fn_obj.is_definition = p.at('{')
		// A `static inline` function has internal linkage even though nothing in the
		// C source says so on the definition.
		fn_obj.is_static = attr.is_static || (attr.is_inline && !attr.is_extern)
	}

	if p.consume(';') {
		return
	}
	if !p.at('{') {
		p.error_here('expected "{" or ";" after a function declaration')
		p.skip_to_decl_end()
		return
	}
	body_start := p.pos

	// The body is parsed in the function's own scope, with the parameters in scope and
	// appended to the frame's object list before anything else, because a local declared
	// later is laid out after them.
	p.pos++
	p.current_fn = fn_obj
	p.locals = []&ast.Obj{}
	p.gotos = []&ast.Node{}
	p.labels = []&ast.Node{}
	p.brk_label = ''
	p.cont_label = ''
	p.enter_scope()
	p.create_param_lvars(fn_obj.ty)

	// A struct or union larger than two registers is returned in memory the caller
	// allocates, and the address arrives as a hidden first parameter.
	rty := fn_obj.ty.ret_type
	if rty != unsafe { nil } && (rty.kind == .struct_ || rty.kind == .union_)
		&& rty.size > 16 {
		p.new_lvar('', pointer_to(rty), line)
	}
	fn_obj.params = p.locals

	// A variadic function needs no local for its `va_list`. On this target the
	// `va_list` is a pointer the caller keeps, and the slots it walks are the home
	// area and the caller's stack area — both already addressed from `%rbp`. The
	// previous phase of this project gave it a 128-byte `__va_area__` holding the
	// psABI's 24-byte tag plus a register save area, which is the System V mechanism
	// and is not what this target uses; `src/ast/abi.v` records the measurement.

	// The high-water mark of the stack a VLA has claimed, which the backend restores on
	// every return and every `goto` out of a block.
	fn_obj.alloca_bottom = p.new_lvar('__alloca_size__', pointer_to(ty_char), line)

	// [C11 6.4.2.2] `__func__` is a local holding the function's own name, and GNU C
	// spells the same thing `__FUNCTION__`. V's generated C uses both.
	//
	// It is an anonymous global rather than a local because its value has to outlive
	// the frame, and it is anonymous because two functions in one file each need one.
	func_ty := array_of(ty_char, fn_obj.name.len + 1)
	mut func_bytes := []u8{}
	for c in fn_obj.name {
		func_bytes << c
	}
	func_bytes << 0
	mut func_obj := p.new_anon_gvar(func_ty, line)
	func_obj.init_data = func_bytes
	p.push_scope('__func__').obj = func_obj
	p.push_scope('__FUNCTION__').obj = func_obj

	body := p.compound_stmt()
	p.leave_scope()
	p.resolve_goto_labels()
	// After the labels exist, because a static local may be initialized from one:
	// `static void *p[] = {&&done}`. Writing the byte image anywhere earlier reads a
	// `unique_label` that is still empty and emits a relocation to nothing.
	p.flush_static_inits()

	fn_obj.body = body.body
	fn_obj.locals = p.locals
	fn_obj.body_start = body_start
	fn_obj.body_end = p.pos
	fn_obj.is_definition = true
	p.current_fn = unsafe { nil }
	p.locals = []&ast.Obj{}
}

// create_param_lvars declares the parameters as locals, in order.
//
// `new_lvar` binds each name in the current scope, so a parameter with an empty name —
// the hidden pointer a large struct return arrives in — is declared without becoming
// visible to the body.
fn (mut p Parser) create_param_lvars(ty &ast.Type) {
	for pty in ty.params {
		mut param := pty
		if param.kind == .array || param.kind == .vla {
			// An array parameter is a pointer to its element; the brackets describe how
			// the caller indexed it, not how it is stored.
			mut adj := pointer_to(param.base)
			adj = copy_type(adj)
			param = adj
		}
		p.new_lvar(param.name, param, ty.name_line)
	}
}

// consume_decl_comma consumes the `,` between two declarators in a declaration list,
// reporting a missing one as the missing `;` it actually is.
//
// A declaration list is `a, b;`, so the grammar really does expect a comma after a
// declarator. Reporting "expected ','" for `int x\nint y;` is accurate and useless:
// what is missing is the semicolon that ends the line above. tcc words this as
// `';' expected (got 'int')` and reports the unexpected token's position, and a corpus
// sweep can only line its diagnostics up with tcc's if this does the same.
//
// It returns false when the separator is missing or the input has ended, so the caller
// can stop rather than loop on a cursor that has not moved.
fn (mut p Parser) consume_decl_comma() bool {
	if p.consume(',') {
		return true
	}
	tok := p.tok()
	if tok.kind == .eof || p.at('}') {
		return false
	}
	p.error_at_help(tok, "';' expected (got '${tok.text}')", 'a declaration or statement ends with `;` — one is missing before this token')
	return false
}

// global_variable parses one or more file-scope variable declarations.
fn (mut p Parser) global_variable(basety &ast.Type, attr VarAttr) {
	mut first := true
	for !p.consume(';') {
		if p.tok().kind == .eof || p.at('}') {
			p.error_here('expected ";" at the end of a declaration')
			return
		}
		if !first && !p.consume_decl_comma() {
			p.skip_to_decl_end()
			return
		}
		first = false
		if p.at(';') {
			continue
		}

		mut ty := p.declarator(basety)
		if ty.name == '' {
			p.error_here('variable name omitted')
			p.skip_to_decl_end()
			return
		}
		mut var := p.new_gvar(ty.name, ty, ty.name_line)
		var.is_definition = !attr.is_extern
		var.is_static = attr.is_static
		var.is_tls = attr.is_tls
		if attr.align != 0 {
			var.align = attr.align
		}
		if p.consume('=') {
			p.gvar_initializer(mut var)
		} else if !attr.is_extern && !attr.is_tls {
			// `int x;` at file scope defines x as zero. Several such declarations are
			// legal, and scan_globals drops the redundant ones.
			var.is_tentative = true
		}
	}
}

// parse_typedef parses a typedef declaration.
fn (mut p Parser) parse_typedef(basety &ast.Type) {
	mut first := true
	for !p.consume(';') {
		if p.tok().kind == .eof || p.at('}') {
			p.error_here('expected ";" at the end of a typedef')
			return
		}
		if !first && !p.consume_decl_comma() {
			p.skip_to_decl_end()
			return
		}
		first = false
		if p.at(';') {
			continue
		}
		mut ty := p.declarator(basety)
		if ty.name == '' {
			p.error_here('typedef name omitted')
			p.skip_to_decl_end()
			return
		}
		mut def := p.push_scope(ty.name)
		def.type_def = ty
	}
}

// skip_to_decl_end advances past the end of a declaration that could not be parsed,
// so that one bad declaration does not hide the rest of the file.
fn (mut p Parser) skip_to_decl_end() {
	mut depth := 0
	for p.tok().kind != .eof {
		if p.at('{') || p.at('(') || p.at('[') {
			depth++
		} else if p.at('}') || p.at(')') || p.at(']') {
			if depth == 0 {
				return
			}
			depth--
		} else if p.at(';') && depth == 0 {
			p.pos++
			return
		}
		p.pos++
	}
}

// scan_globals drops tentative definitions that another definition makes redundant.
//
// C allows `int x;` to be written more than once, and also `int x; int x = 1;`. Only
// the initialized one is a definition; emitting both would give the linker two
// definitions of the same symbol. When several tentatives exist and nothing is
// initialized, exactly one of them is kept, because dropping them all would leave the
// variable with no definition at all — which is chibicc's behaviour and is wrong.
fn (mut p Parser) scan_globals() {
	mut initialized := map[string]bool{}
	for obj in p.globals {
		if obj.is_definition && !obj.is_tentative {
			initialized[obj.name] = true
		}
	}
	mut kept_tentative := map[string]bool{}
	mut kept := []&ast.Obj{}
	for obj in p.globals {
		if !obj.is_tentative {
			kept << obj
			continue
		}
		if initialized[obj.name] || kept_tentative[obj.name] {
			continue
		}
		kept_tentative[obj.name] = true
		kept << obj
	}
	p.globals = kept
}

// --- local declarations ---
//
// A local declaration is written here even though function bodies are not parsed yet:
// it is the other half of what `declaration` means, it is what a `static` local and
// a variable-length array need, and it is reachable from a test through
// `Parser.declaration` without a body.

// declaration parses a declaration inside a block and returns the statements that
// carry it out.
//
//	declaration = declspec (declarator ("=" initializer)? ("," …)*)? ";"
fn (mut p Parser) declaration(basety &ast.Type, attr VarAttr) &ast.Node {
	tok := p.tok()
	mut stmts := []&ast.Node{}

	for !p.consume(';') {
		if p.tok().kind == .eof || p.at('}') {
			p.error_here('expected ";" at the end of a declaration')
			break
		}
		if stmts.len > 0 && !p.consume_decl_comma() {
			p.skip_to_decl_end()
			break
		}
		if p.at(';') {
			continue
		}

		mut ty := p.declarator(basety)
		if ty.name == '' {
			p.error_here('variable name omitted')
			p.skip_to_decl_end()
			break
		}
		if ty.kind == .basic && ty.basic == .void_ {
			p.error_here('variable declared void')
		}

		// A static local has static storage: it becomes an anonymous global, and the
		// name in this block refers to it.
		if attr.is_static {
			mut obj := p.new_anon_gvar(ty, ty.name_line)
			p.push_scope(ty.name).obj = obj
			if p.consume('=') {
				// The deferred form, not `gvar_initializer`: the initializer may name a
				// label, and a label cannot be spelled until the body has been read.
				p.gvar_initializer_in_function(mut obj)
			}
			continue
		}

		// The size of a variable-length array has to be computed before anything can
		// address it. This runs even for a pointer to a VLA, whose size is still
		// computed: `int (*p)[n][m]` mentions two of them.
		stmts << p.expr_stmt_of(p.compute_vla_size(mut ty, p.tok()))

		if ty.kind == .vla {
			if p.at('=') {
				p.error_here('a variable-sized object may not be initialized')
			}
			// A VLA is translated into a call to the allocator: `int x[n+2]` becomes
			// `tmp = n+2; x = alloca(tmp)`, with `x` holding the pointer.
			mut obj := p.new_lvar(ty.name, ty, ty.name_line)
			size := p.new_var_node(ty.vla_size, tok)
			mut assign := p.new_binary(.assign, p.new_vla_ptr_node(obj, tok),
				p.new_alloca(size, tok), tok)
			add_type(mut assign)
			stmts << p.expr_stmt_of(assign)
			continue
		}

		mut obj := p.new_lvar(ty.name, ty, ty.name_line)
		if attr.align != 0 {
			obj.align = attr.align
		}
		if p.consume('=') {
			stmts << p.expr_stmt_of(p.lvar_initializer(mut obj))
		}
		if !obj.ty.is_complete() {
			p.error_here('variable "${obj.name}" has an incomplete type')
		}
	}

	mut block := p.new_node(.block_, tok)
	block.body = stmts
	return block
}

// new_vla_ptr_node reads the pointer a variable-length array was allocated into,
// which is what addressing such an array goes through.
fn (p &Parser) new_vla_ptr_node(obj &ast.Obj, tok ast.Token) &ast.Node {
	return &ast.Node{
		kind: .vla_ptr
		tok:  tok
		var:  obj
	}
}

// expr_stmt_of wraps an expression as a statement.
fn (p &Parser) expr_stmt_of(expr &ast.Node) &ast.Node {
	return &ast.Node{
		kind: .expr_stmt
		tok:  expr.tok
		lhs:  expr
	}
}

// --- initializers ---

// new_initializer builds the initializer tree for a type.
//
// The tree is shaped like the type, so every scalar leaf has somewhere to put its
// expression whether or not the source initializes it. That is what makes the
// "unspecified elements are zero" rule a matter of leaving leaves alone rather than
// of checking for them.
fn (mut p Parser) new_initializer(ty &ast.Type, is_flexible bool) &Initializer {
	mut init := &Initializer{
		ty:          ty
		is_flexible: false
		children:    []&Initializer{}
		mem_index:   -1
	}
	if ty.kind == .array {
		if is_flexible && ty.size_or_known() == none {
			init.is_flexible = true
			return init
		}
		for _ in 0 .. ty.array_len {
			init.children << p.new_initializer(ty.base, false)
		}
		return init
	}
	if ty.kind == .struct_ || ty.kind == .union_ {
		for mem in ty.members {
			// The last member of a flexible array is itself flexible, and its length
			// comes from the initializer.
			if is_flexible && ty.is_flexible && mem == ty.members.last() {
				mut child := &Initializer{
					ty:          mem.ty
					is_flexible: true
					children:    []&Initializer{}
					mem_index:   -1
				}
				init.children << child
				continue
			}
			init.children << p.new_initializer(mem.ty, false)
		}
		return init
	}
	return init
}

// initializer parses an initializer and returns it, completing the type where the
// initializer is what says how long an array is.
fn (mut p Parser) initializer(ty &ast.Type) (&Initializer, &ast.Type) {
	mut init := p.new_initializer(ty, true)
	p.initializer2(mut init)

	// A struct with a flexible array member is completed by the initializer, so it
	// needs a copy: the type it completes may be shared with other declarations.
	if (ty.kind == .struct_ || ty.kind == .union_) && ty.is_flexible {
		mut completed := copy_type(ty)
		if completed.members.len > 0 {
			last := completed.members.len - 1
			tail := init.children[last]
			completed.members[last].ty = tail.ty
			completed.size = ty.size + tail.ty.size
		}
		return init, completed
	}
	return init, init.ty
}

// initializer2 parses whatever form of initializer the target type calls for.
//
// Note on the `mut child := init.children[i]` lines at its call sites: passing `mut`
// directly on a slice element of reference type produces a bad pointer in this V build
// and crashes on the first write. Binding the element to a local first works, and is
// what every one of those sites does. See notes/DECISIONS.md.
fn (mut p Parser) initializer2(mut init &Initializer) {
	ty := init.ty

	if ty.kind == .array && p.tok().kind == .str_ {
		p.string_initializer(mut init)
		return
	}
	if ty.kind == .array {
		if p.at('{') {
			p.array_initializer1(mut init)
		} else {
			p.array_initializer2(mut init, 0)
		}
		return
	}
	if ty.kind == .struct_ {
		if p.at('{') {
			p.struct_initializer1(mut init)
			return
		}
		// A struct can be initialized from another struct of the same type: `struct T
		// x = y;`. That has to be tried before treating the braces as a member list,
		// because the source may have neither.
		mut node := p.const_expr_node()
		add_type(mut node)
		if node.ty.kind == .struct_ {
			init.expr = node
			return
		}
		p.struct_initializer2(mut init, 0)
		return
	}
	if ty.kind == .union_ {
		p.union_initializer(mut init)
		return
	}
	if p.at('{') {
		// A scalar may be braced: `int x = {3};`.
		p.pos++
		p.initializer2(mut init)
		p.expect('}')
		return
	}
	init.expr = p.const_expr_node()
}

// string_run consumes the run of adjacent string literals at the cursor and returns it,
// leaving the cursor after the last one.
//
// [C11 6.4.5p5] Adjacent string literals are one literal, so `sizeof("abc" "def")` is 8
// and not 4. It used to parse as `"abc"` and then trip over the second token, which the
// missing `)` never consumed, so the parser re-read the same tokens until the heap gave
// out. Both places a literal can appear go through here, because a run that works in an
// expression and not in an initializer is not a feature.
fn (mut p Parser) string_run() []ast.Token {
	mut run := [p.tok()]
	p.pos++
	for p.tok().kind == .str_ {
		run << p.tok()
		p.pos++
	}
	return run
}

// string_literal_value lays a run of literals end to end into one array of the first
// piece's element type.
//
// The run has one width, which the first piece decides. [C11 6.4.5p5] makes a mismatched
// prefix undefined rather than an error, and both tcc and chibicc take the first piece's
// width and say nothing. Rejecting the mix would be a third answer and the least useful
// one: it is not the behaviour being replaced.
//
// Each piece is decoded by the same `string_unit` a lone literal uses — re-encoding the
// decoded bytes would turn `"\xff"` into two UTF-8 bytes and change what `"\xff"[0]` is
// — and one terminator is written for the whole run, not one per piece.
fn string_literal_value(pieces []ast.Token) (&ast.Type, []u8) {
	elem := string_element_type(&pieces[0])
	mut count := 0
	for piece in pieces {
		count += code_point_count(piece.str_data)
	}
	sz := elem.size
	ty := array_of(elem, count + 1)
	// Zero-initialised, so the single terminating NUL at the end is already written.
	mut buf := []u8{len: sz * ty.array_len, init: 0}
	mut at := 0
	for piece in pieces {
		for i in 0 .. code_point_count(piece.str_data) {
			write_int(mut buf, at * sz, u64(string_unit(piece, i, sz)), sz)
			at++
		}
	}
	return ty, buf
}

// string_literal_expr is a string literal, together with every literal written next to
// it, as the anonymous global its value needs to live in.
fn (mut p Parser) string_literal_expr() &ast.Node {
	pieces := p.string_run()
	ty, buf := string_literal_value(pieces)
	mut obj := p.new_anon_gvar(ty, pieces[0].line.disp_line)
	obj.init_data = buf
	return p.new_var_node(obj, pieces[0])
}

// string_initializer initializes an array from a string literal.
//
// The *declared* array's element type decides the stride, and the literal's own element
// type does not: [C11 6.4.5p5] lets a string literal initialize an array of character
// type, and the element count is what the literal contributes. So `char x[] = "abc"` is
// four bytes, and `unsigned int x[] = L"abc"` is twelve — three wide characters in
// four-byte slots.
//
// Sizing from the literal was wrong, and invisible for as long as the two agreed.
// `array_of(elem, lit.array_len)` already builds the array at the declared element's
// width, so overwriting its size with the literal's own dropped a declared array to the
// literal's narrower stride: `int w[] = L"ab"` came out six bytes rather than twelve.
// That construct is ill-formed — gcc rejects it outright as `array of inappropriate type
// initialized from string constant`, and tcc reads the literal as a pointer and warns —
// so nothing caught it.
//
// The terminating NUL is included, and a shorter literal in a longer array leaves the
// rest zero.
fn (mut p Parser) string_initializer(mut init &Initializer) {
	run := p.string_run()
	lit, _ := string_literal_value(run)

	if init.is_flexible {
		// The array's *length* is the literal's, including the NUL. Its size is not:
		// `array_of` has already computed that from the declared element type, and this
		// used to overwrite it with the literal's own.
		mut resized := p.new_initializer(array_of(init.ty.base, lit.array_len), false)
		init.ty = resized.ty
		init.is_flexible = false
		init.children = resized.children
	}

	elem := init.ty.base
	n := if init.ty.array_len < lit.array_len {
		init.ty.array_len
	} else {
		lit.array_len
	}
	// The run's elements laid end to end, so element k of the merged literal is element
	// k of the run however many pieces it was written as.
	mut units := []i64{}
	for piece in run {
		for i in 0 .. code_point_count(piece.str_data) {
			units << string_unit(piece, i, elem.size)
		}
	}
	tok := run[0]
	for i in 0 .. n {
		// Past the end of the literal the array's own zero-initializer supplies the NUL
		// and any remaining elements, which is what a shorter literal in a longer array
		// is specified to leave behind.
		if i < units.len {
			init.children[i].expr = p.new_num(units[i], tok)
		}
	}
}

// string_unit returns element i of a string literal's value.
//
// The tokenizer decodes escapes into raw bytes, so a wide literal's bytes are UTF-8
// and have to be re-encoded into 2- or 4-byte units. A `\u` escape would already
// have been mis-decoded by the tokenizer; V does not emit one, and the case is
// recorded rather than silently mis-encoded.
fn string_unit(tok &ast.Token, i int, elem_size int) i64 {
	if elem_size == 1 {
		if i < tok.str_data.len {
			return i64(tok.str_data[i])
		}
		return 0
	}
	code, _ := utf8_at(tok.str_data, i)
	return i64(code)
}

// utf8_at returns the i'th code point of a byte sequence and how many bytes it used.
fn utf8_at(data []u8, i int) (int, int) {
	mut pos := 0
	for _ in 0 .. i {
		if pos >= data.len {
			return 0, 0
		}
		_, n := decode_utf8_one(data, pos)
		pos += n
	}
	if pos >= data.len {
		return 0, 0
	}
	return decode_utf8_one(data, pos)
}

// code_point_count returns how many code points a UTF-8 byte sequence holds.
fn code_point_count(data []u8) int {
	mut n := 0
	mut pos := 0
	for pos < data.len {
		_, width := decode_utf8_one(data, pos)
		pos += if width < 1 { 1 } else { width }
		n++
	}
	return n
}

// decode_utf8_one reads the code point at pos and returns it with its length.
//
// It exists because the tokenizer produces bytes, and a wide string literal needs
// code points. Malformed input yields the replacement character and one byte, so a
// bad sequence cannot make the parser loop.
fn decode_utf8_one(data []u8, pos int) (int, int) {
	b := int(data[pos])
	if b < 0x80 {
		return b, 1
	}
	mut n := 0
	mut c := 0
	if b & 0xe0 == 0xc0 {
		n, c = 1, b & 0x1f
	} else if b & 0xf0 == 0xe0 {
		n, c = 2, b & 0x0f
	} else if b & 0xf8 == 0xf0 {
		n, c = 3, b & 0x07
	} else {
		return 0xfffd, 1
	}
	if pos + n >= data.len {
		return 0xfffd, 1
	}
	for i in 1 .. n + 1 {
		nb := int(data[pos + i])
		if nb & 0xc0 != 0x80 {
			return 0xfffd, 1
		}
		c = (c << 6) | (nb & 0x3f)
	}
	return c, n + 1
}

// array_initializer1 parses a braced array initializer.
//
//	array-initializer1 = "{" initializer ("," initializer)* ","? "}"
fn (mut p Parser) array_initializer1(mut init &Initializer) {
	p.expect('{')
	p.resize_flexible_array(mut init)

	mut i := 0
	mut first := true
	for !p.consume_end() {
		if p.tok().kind == .eof {
			p.error_here('unterminated initializer')
			return
		}
		if !first {
			p.expect(',')
		}
		first = false

		// A designator moves the cursor: `[5] = 3` initializes the sixth element and
		// the following values continue from there, leaving the ones in between zero.
		if p.at('[') {
			begin, end := p.array_designator(init.ty)
			for j in begin .. end + 1 {
				mut child := init.children[j]
				p.designation(mut child)
			}
			i = end + 1
			continue
		}
		if i < init.ty.array_len {
			mut child := init.children[i]
			p.initializer2(mut child)
		} else {
			p.skip_excess_element()
		}
		i++
	}
}

// array_initializer2 parses an unbraced array initializer, which is what the tail of
// a nested one looks like: the inner array of `int x[2][2] = {1,2,3,4}` starts
// without its own braces.
//
//	array-initializer2 = initializer ("," initializer)*
fn (mut p Parser) array_initializer2(mut init &Initializer, start int) int {
	p.resize_flexible_array(mut init)
	mut i := start
	for i < init.ty.array_len && !p.is_end() {
		before := p.pos
		if i > 0 {
			p.expect(',')
		}
		if p.at('[') || p.at('.') {
			// A designator ends this run; the caller handles it.
			p.pos = before
			return i
		}
		mut child := init.children[i]
		p.initializer2(mut child)
		i++
	}
	return i
}

// resize_flexible_array gives a flexible array its length from the initializer.
//
// `int x[] = {1,2,3}` has no length in the declarator, so the number of elements is
// counted first and the initializer is then rebuilt at that size. The cursor is put
// back before the second pass, because the count is a *parse* of the elements rather
// than a lookahead: chibicc threads a copy of the token list through the counting
// function, and the shared cursor is this parser's equivalent of that copy.
fn (mut p Parser) resize_flexible_array(mut init &Initializer) {
	if !init.is_flexible {
		return
	}
	save := p.pos
	n := p.count_array_init_elements(init.ty.base)
	p.pos = save
	resized := p.new_initializer(array_of(init.ty.base, n), false)
	init.ty = resized.ty
	init.is_flexible = false
	init.children = resized.children
}

// count_array_init_elements counts the elements a braced array initializer has.
//
// It parses the initializer twice: once to count, once to fill. That is what chibicc
// does, and the alternative — remembering where each element started — costs more
// than the second parse of a construct that is nearly always short.
fn (mut p Parser) count_array_init_elements(base &ast.Type) int {
	mut dummy := p.new_initializer(base, true)
	mut i := 0
	mut max := 0
	mut first := true
	for !p.consume_end() {
		if p.tok().kind == .eof {
			break
		}
		if !first {
			p.expect(',')
		}
		first = false
		if p.at('[') {
			i = int(p.const_expr())
			if p.consume('...') {
				i = int(p.const_expr())
			}
			p.expect(']')
			p.designation(mut dummy)
		} else {
			p.initializer2(mut dummy)
		}
		i++
		if i > max {
			max = i
		}
	}
	return max
}

// member_takes_initializer reports whether a member is initialized positionally.
//
// A zero-width bitfield is not a field at all — it is a padding directive — so it takes
// no initializer and no designator. Skipping it is what keeps the members after it lined
// up with the values in the source; treating it as a field silently shifts every
// initializer after it by one.
fn member_takes_initializer(m &ast.Member) bool {
	return !(m.is_bitfield && m.bit_width == 0)
}

// next_init_member returns the index of the first member at or after `from` that takes
// an initializer, or the member count if there is none.
fn next_init_member(ty &ast.Type, from int) int {
	mut i := from
	for i < ty.members.len {
		if member_takes_initializer(&ty.members[i]) {
			return i
		}
		i++
	}
	return ty.members.len
}

// struct_initializer1 parses a braced struct initializer.
//
//	struct-initializer1 = "{" initializer ("," initializer)* ","? "}"
fn (mut p Parser) struct_initializer1(mut init &Initializer) {
	p.expect('{')
	mut index := next_init_member(init.ty, 0)
	mut first := true
	for !p.consume_end() {
		if p.tok().kind == .eof {
			p.error_here('unterminated initializer')
			return
		}
		if !first {
			p.expect(',')
		}
		first = false
		if p.at('.') {
			index = p.struct_designator(init.ty)
			mut child := init.children[index]
			p.designation(mut child)
			index = next_init_member(init.ty, index + 1)
			continue
		}
		if index < init.ty.members.len {
			mut child := init.children[index]
			p.initializer2(mut child)
			index = next_init_member(init.ty, index + 1)
		} else {
			p.skip_excess_element()
		}
	}
}

// struct_initializer2 parses an unbraced struct initializer, which is the tail of a
// nested one.
fn (mut p Parser) struct_initializer2(mut init &Initializer, start int) {
	mut index := next_init_member(init.ty, start)
	for index < init.ty.members.len && !p.is_end() {
		before := p.pos
		if index > start {
			p.expect(',')
		}
		if p.at('[') || p.at('.') {
			p.pos = before
			return
		}
		mut child := init.children[index]
		p.initializer2(mut child)
		index = next_init_member(init.ty, index + 1)
	}
}

// union_initializer parses a union initializer.
//
// Unlike a struct, a union takes one initializer, which initializes its first member
// unless a designator names another.
fn (mut p Parser) union_initializer(mut init &Initializer) {
	if p.at('{') && p.tok_at(1).text == '.' {
		p.pos++
		index := p.struct_designator(init.ty)
		init.mem_index = index
		mut child := init.children[index]
		p.designation(mut child)
		p.expect('}')
		return
	}
	if init.ty.members.len == 0 {
		return
	}
	init.mem_index = 0
	if p.at('{') {
		p.pos++
		mut child := init.children[0]
		p.initializer2(mut child)
		p.consume(',')
		p.expect('}')
		return
	}
	mut child := init.children[0]
	p.initializer2(mut child)
}

// designation parses a designated initializer and continues into it.
//
//	designation = ("[" const-expr "]" | "." ident)* "="? initializer
//
// A chain of designators walks down to a scalar, which is what makes `[1][3] = 5`
// mean the same as it does in gcc.
fn (mut p Parser) designation(mut init &Initializer) {
	if p.at('[') {
		if init.ty.kind != .array {
			p.error_here('array index in a non-array initializer')
			p.initializer2(mut init)
			return
		}
		begin, end := p.array_designator(init.ty)
		for i in begin .. end + 1 {
			mut child := init.children[i]
			p.designation(mut child)
		}
		p.array_initializer2(mut init, end + 1)
		return
	}
	if p.at('.') && (init.ty.kind == .struct_ || init.ty.kind == .union_) {
		index := p.struct_designator(init.ty)
		if init.ty.kind == .union_ {
			init.mem_index = index
		}
		mut child := init.children[index]
		p.designation(mut child)
		if init.ty.kind == .struct_ {
			p.struct_initializer2(mut init, index + 1)
		}
		return
	}
	if p.at('.') {
		p.error_here('field name in an initializer of a non-struct')
	}
	p.consume('=')
	p.initializer2(mut init)
}

// array_designator parses `[const-expr]` or `[const-expr ... const-expr]` and returns
// the first and last index it names.
fn (mut p Parser) array_designator(ty &ast.Type) (int, int) {
	p.expect('[')
	begin := int(p.const_expr())
	if ty.array_len >= 0 && begin >= ty.array_len {
		p.error_here('array designator index ${begin} exceeds the array bounds')
	}
	mut end := begin
	if p.consume('...') {
		end = int(p.const_expr())
		if ty.array_len >= 0 && end >= ty.array_len {
			p.error_here('array designator index ${end} exceeds the array bounds')
		}
		if end < begin {
			p.error_here('array designator range is empty')
		}
	}
	p.expect(']')
	return begin, end
}

// struct_designator parses `.name` and returns the member's index.
fn (mut p Parser) struct_designator(ty &ast.Type) int {
	p.expect('.')
	tok := p.tok()
	if tok.kind != .ident {
		p.error_here('expected a field designator')
		p.pos++
		return 0
	}
	index := p.get_struct_member(ty, tok.text) or {
		p.error_here('struct has no member named "${tok.text}"')
		0
	}
	// An anonymous member's field is reached through the anonymous member itself, so
	// the designator has to name the member the parser will descend into.
	p.pos++
	return index
}

// skip_excess_element parses an initializer the target type has no room for.
//
// It has to consume the value or the rest of the list would be read as the next
// element's value.
fn (mut p Parser) skip_excess_element() {
	if p.at('{') {
		p.pos++
		p.skip_excess_element()
		p.expect('}')
		return
	}
	p.const_expr_node()
}

// --- constant expressions ---

// const_expr parses a constant expression and returns its value.
fn (mut p Parser) const_expr() i64 {
	mut node := p.const_expr_node()
	return eval(mut node)
}

// const_expr_node parses a constant expression and returns the node.
//
// Only the forms C allows in a constant expression are parsed: literals, named
// constants, operators, casts, `sizeof`, `_Alignof`, and the address of a global.
// Anything else becomes a `.generic` node with a diagnostic, so the parse continues
// and a corpus sweep finds the whole list rather than only the first entry.
//
// `assignments` counts the compound assignments seen while parsing. A constant
// expression must contain none, but they have to be parsed to reach the end of the
// initializer, which is why the count is on the parser.
fn (mut p Parser) const_expr_node() &ast.Node {
	return p.conditional()
}

// conditional = logor ("?" expr ":" conditional)?
//
// The middle of a conditional can be any expression, not a constant one: `x ? f() :
// 1` is legal. Here only the constant form is parsed, and a non-constant middle is
// reported rather than mis-evaluated.
// conditional parses `c ? a : b`, and the GNU form `a ?: b`.
//
// The middle operand of `?:` may be left out, and then it is the condition again: the
// whole expression is `a` when `a` is nonzero and `b` when it is zero. Written out as
// `a ? a : b` here rather than as its own node kind, because there is nothing else for
// the backend to do differently.
fn (mut p Parser) conditional() &ast.Node {
	cond := p.logor()
	if !p.at('?') {
		return cond
	}
	tok := p.next()
	// The middle operand of `?:` may be left out, and then it is the condition again.
	// It is recorded as a flag rather than left to be discovered by comparing `then` and
	// `cond`, because `add_type` casts each branch and the cast replaces the pointer.
	gnu := p.at(':')
	then := if gnu { cond } else { p.conditional() }
	p.expect(':')
	els := p.conditional()
	mut node := p.new_node(.cond_expr, tok)
	node.cond = cond
	node.then = then
	node.els = els
	node.then_is_cond = gnu
	add_type(mut node)
	return node
}

fn (mut p Parser) logor() &ast.Node {
	mut node := p.logand()
	for p.at('||') {
		tok := p.next()
		rhs := p.logand()
		node = p.new_binary(.log_or, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) logand() &ast.Node {
	mut node := p.bitor()
	for p.at('&&') {
		tok := p.next()
		rhs := p.bitor()
		node = p.new_binary(.log_and, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) bitor() &ast.Node {
	mut node := p.bitxor()
	for p.at('|') {
		tok := p.next()
		rhs := p.bitxor()
		node = p.new_binary(.bit_or, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) bitxor() &ast.Node {
	mut node := p.bitand()
	for p.at('^') {
		tok := p.next()
		rhs := p.bitand()
		node = p.new_binary(.bit_xor, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) bitand() &ast.Node {
	mut node := p.equality()
	for p.at('&') {
		tok := p.next()
		rhs := p.equality()
		node = p.new_binary(.bit_and, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) equality() &ast.Node {
	mut node := p.relational()
	for p.at('==') || p.at('!=') {
		tok := p.next()
		rhs := p.relational()
		kind := if tok.text == '==' { ast.NodeKind.eq } else { ast.NodeKind.ne }
		node = p.new_binary(kind, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) relational() &ast.Node {
	mut node := p.shift()
	for p.at('<') || p.at('<=') || p.at('>') || p.at('>=') {
		tok := p.next()
		rhs := p.shift()
		// `>` and `>=` are the two relational operators with their operands the
		// other way round rather than operators of their own, so the backend needs
		// only `lt` and `le`.
		if tok.text == '>' || tok.text == '>=' {
			kind := if tok.text == '>' { ast.NodeKind.lt } else { ast.NodeKind.le }
			node = p.new_binary(kind, rhs, node, tok)
		} else {
			kind := if tok.text == '<' { ast.NodeKind.lt } else { ast.NodeKind.le }
			node = p.new_binary(kind, node, rhs, tok)
		}
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) shift() &ast.Node {
	mut node := p.additive()
	for p.at('<<') || p.at('>>') {
		tok := p.next()
		rhs := p.additive()
		kind := if tok.text == '<<' { ast.NodeKind.shl } else { ast.NodeKind.shr }
		node = p.new_binary(kind, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) additive() &ast.Node {
	mut node := p.multiplicative()
	for p.at('+') || p.at('-') {
		tok := p.next()
		mut rhs := p.multiplicative()
		// `new_add` and `new_sub`, not `new_binary`, because a binary `+` or `-` is
		// where pointer arithmetic happens and it has to scale: [C11 6.5.6p8] `p + n`
		// is `p + n * sizeof(*p)`.
		//
		// This built the node directly, so `new_binary` ran, `add_type` applied the
		// *usual arithmetic conversions* to it, and nothing scaled. `int *p; p + 1`
		// advanced one byte for every element type — four for an `int`, eight for a
		// `double`, one for a `char`, where the last was right by accident and the other
		// two were not. `q[1]`, `q += 1` and `q++` all scaled, because the subscript and
		// the compound-assignment paths go through `new_add`; only the plain operator
		// did not, so `p + 1` and `p[1]` disagreed with each other by a factor of four
		// in the same expression.
		//
		// The scaling lives in these two builders rather than in `add_type` because
		// `add_type` is a free function with no access to the parser's node builders, and
		// because it is idempotent: a node that already has a type is left alone, so a
		// second `add_type` cannot scale twice.
		node = if tok.text == '+' {
			p.new_add(mut node, mut rhs, tok)
		} else {
			p.new_sub(mut node, mut rhs, tok)
		}
		add_type(mut node)
	}
	return node
}

fn (mut p Parser) multiplicative() &ast.Node {
	mut node := p.cast_expr()
	for p.at('*') || p.at('/') || p.at('%') {
		tok := p.next()
		mut rhs := p.cast_expr()
		kind := match tok.text {
			'*' { ast.NodeKind.mul }
			'/' { ast.NodeKind.div }
			else { ast.NodeKind.mod }
		}
		node = p.new_binary(kind, node, rhs, tok)
		add_type(mut node)
	}
	return node
}

// cast_expr parses a cast or falls through to unary.
//
// A parenthesised type is a cast unless a `{` follows it, in which case it is a
// compound literal — the same distinction chibicc makes.
fn (mut p Parser) cast_expr() &ast.Node {
	if p.at('(') && p.is_typename_at(1) {
		start := p.pos
		p.pos++
		ty := p.typename()
		p.expect(')')
		if p.at('{') {
			return p.compound_literal(ty, start)
		}
		operand := p.cast_expr()
		mut node := new_cast(operand, ty)
		node.tok = p.toks[start]
		return node
	}
	return p.unary()
}

// is_typename_at reports whether the token n positions ahead can begin a type.
fn (mut p Parser) is_typename_at(n int) bool {
	save := p.pos
	p.pos += n
	ans := p.is_typename()
	p.pos = save
	return ans
}

// compound_literal initializes an anonymous object: `(struct S){1, 2}`.
fn (mut p Parser) compound_literal(ty &ast.Type, start int) &ast.Node {
	if p.scopes.len <= 1 {
		// At file scope a compound literal has static storage, so it becomes a
		// global with a generated name.
		mut obj := p.new_anon_gvar(ty, p.toks[start].line.disp_line)
		p.gvar_initializer(mut obj)
		return p.new_var_node(obj, p.toks[start])
	}
	mut obj := p.new_lvar('', ty, p.toks[start].line.disp_line)
	mut init := p.lvar_initializer(mut obj)
	return p.new_binary(.comma, init, p.new_var_node(obj, p.toks[start]),
		p.toks[start])
}

// unary parses a unary expression.
fn (mut p Parser) unary() &ast.Node {
	tok := p.tok()
	if p.at('+') {
		p.pos++
		return p.cast_expr()
	}
	if p.at('-') {
		p.pos++
		operand := p.cast_expr()
		mut node := p.new_unary(.neg, operand, tok)
		add_type(mut node)
		return node
	}
	if p.at('&') {
		p.pos++
		mut operand := p.cast_expr()
		add_type(mut operand)
		if operand.kind == .member {
			if m := operand.member {
				if m.is_bitfield {
					p.error_at(tok, 'cannot take the address of a bitfield')
				}
			}
		}
		mut node := p.new_unary(.addr, operand, tok)
		add_type(mut node)
		return node
	}
	if p.at('*') {
		p.pos++
		mut operand := p.cast_expr()
		add_type(mut operand)
		// Dereferencing a function is a no-op: `*f`, `**f` and `f` are the same thing.
		if operand.ty.kind == .func {
			return operand
		}
		mut node := p.new_unary(.deref, operand, tok)
		add_type(mut node)
		return node
	}
	if p.at('!') {
		p.pos++
		operand := p.cast_expr()
		mut node := p.new_unary(.not, operand, tok)
		add_type(mut node)
		return node
	}
	if p.at('~') {
		p.pos++
		operand := p.cast_expr()
		mut node := p.new_unary(.bit_not, operand, tok)
		add_type(mut node)
		return node
	}
	// A prefix `++i` is `i += 1`, and the result is the new value, so no arithmetic is
	// needed to recover it — which is the whole difference from the postfix form.
	if p.at('++') {
		p.pos++
		mut operand := p.unary()
		mut one := p.new_num(1, tok)
		add_type(mut one)
		return p.to_assign(p.new_add(mut operand, mut one, tok))
	}
	if p.at('--') {
		p.pos++
		mut operand := p.unary()
		mut one := p.new_num(1, tok)
		add_type(mut one)
		return p.to_assign(p.new_sub(mut operand, mut one, tok))
	}
	// [GNU] Labels as values: `&&label` is the label's address.
	if p.at('&&') && p.tok_at(1).kind == .ident {
		p.pos++
		mut node := p.new_node(.goto_expr, tok)
		node.label_name = p.tok().text
		node.unique_label = ''
		p.pos++
		p.gotos << node
		return node
	}
	return p.postfix()
}

// postfix parses a primary expression and any chain of calls, `[]`, `.`, `->`, `++`
// and `--` on it.
fn (mut p Parser) postfix() &ast.Node {
	if p.at('(') && p.is_typename_at(1) {
		start := p.pos
		p.pos++
		ty := p.typename()
		p.expect(')')
		return p.compound_literal(ty, start)
	}
	mut node := p.primary()
	for {
		if p.at('(') {
			p.pos++
			node = p.funcall(node)
			continue
		}
		if p.at('[') {
			tok := p.next()
			mut idx := p.conditional()
			p.expect(']')
			// `x[y]` is `*(x + y)`, which is what makes `1[a]` legal.
			sum := p.new_add(mut node, mut idx, tok)
			node = p.new_unary(.deref, sum, tok)
			add_type(mut node)
			continue
		}
		if p.at('.') {
			// The dot is consumed here and `struct_ref` reads the name after it, so the
			// two functions between them own one token each.
			p.pos++
			node = p.struct_ref(mut node)
			continue
		}
		if p.at('->') {
			p.pos++
			node = p.new_unary(.deref, node, p.tok())
			add_type(mut node)
			node = p.struct_ref(mut node)
			continue
		}
		// `A++` is `(typeof A)((A += 1) - 1)`: the value of the expression is A's old
		// value, which no single node can carry across an assignment.
		if p.at('++') {
			node = p.new_inc_dec(node, p.next(), 1)
			continue
		}
		if p.at('--') {
			node = p.new_inc_dec(node, p.next(), -1)
			continue
		}
		return node
	}
}

// struct_ref parses `.name` on a node and returns the member access.
// struct_ref reads the member name after a `.` or `->` and returns the member access.
//
// The dot is the caller's to consume: `->` is a token of its own and `.` is not, so each
// caller consumes exactly one token and this reads exactly one.
fn (mut p Parser) struct_ref(mut node &ast.Node) &ast.Node {
	add_type(mut node)
	tok := p.next()
	if tok.kind != .ident {
		p.error_here('expected a member name after "."')
		return node
	}
	if node.ty.kind != .struct_ && node.ty.kind != .union_ {
		p.error_at(tok, 'member access on a value that is not a struct or union')
		return node
	}
	mut idx := p.get_struct_member(node.ty, tok.text) or {
		p.error_at(tok, 'no member named "${tok.text}"')
		return node
	}
	// An anonymous member's field is reached by stepping through the anonymous
	// member, so the lookup descends until a named member matches.
	//
	// This is a loop rather than a recursion back into `struct_ref`, because the member
	// name was read once, above. The recursive version read it a second time, so every
	// access through an anonymous member ate the token *after* the field name — and the
	// next thing it found was usually not an identifier, which is why this surfaced as
	// `expected a member name after "."` on `y.a` and on nothing else.
	mut base := node
	for {
		mem := base.ty.members[idx]
		mut step := p.new_node(.member, tok)
		step.lhs = base
		step.member = mem
		add_type(mut step)
		if mem.name != '' {
			return step
		}
		base = step
		idx = p.get_struct_member(base.ty, tok.text) or {
			p.error_at(tok, 'no member named "${tok.text}"')
			return base
		}
	}
}

// primary parses the leaves: literals, names, parenthesised expressions and the
// builtins that are compile-time constants.
fn (mut p Parser) primary() &ast.Node {
	tok := p.tok()

	if p.at('(') && p.tok_at(1).text == '{' {
		// [GNU] A statement expression. Its value is its last expression statement, so
		// it needs the statement parser.
		p.pos += 2
		mut node := p.new_node(.stmt_expr, tok)
		block := p.compound_stmt()
		node.body = block.body
		p.expect(')')
		return node
	}
	if p.at('(') {
		p.pos++
		// A parenthesised expression is a whole expression, so the comma operator is
		// available inside it: `(1,2,3)` is 3, and `sizeof (1,2,3)` is the size of an
		// `int`. Reading only a conditional here stopped at the first comma and reported
		// `expected ")", found ","`, which is a diagnostic for perfectly ordinary C.
		node := p.expr()
		p.expect(')')
		return node
	}
	if tok.text == 'sizeof' && p.tok_at(1).text == '(' && p.is_typename_at(2) {
		p.pos += 2
		ty := p.typename()
		p.expect(')')
		return p.size_of_type(ty, tok)
	}
	if tok.text == 'sizeof' {
		p.pos++
		mut node := p.unary()
		add_type(mut node)
		return p.size_of_type(node.ty, tok)
	}
	if tok.text == '_Alignof' && p.tok_at(1).text == '(' && p.is_typename_at(2) {
		p.pos += 2
		ty := p.typename()
		p.expect(')')
		return p.new_size_t(i64(ty.align), tok)
	}
	if tok.text == '_Alignof' {
		// C11 only allows a type name here. gcc, clang, tcc and chibicc all also accept
		// an expression, and V's own generated C uses that form, so it is accepted too:
		// the alignment asked for is the alignment of the expression's type either way,
		// which is the same answer the type-name spelling gives.
		p.pos++
		mut node := p.unary()
		add_type(mut node)
		return p.new_size_t(i64(node.ty.align), tok)
	}
	if tok.text == '__builtin_types_compatible_p' {
		p.pos += 2
		t1 := p.typename()
		p.expect(',')
		t2 := p.typename()
		p.expect(')')
		return p.new_num(i64(int(is_compatible(t1, t2))), tok)
	}
	if tok.text == '__builtin_constant_p' {
		p.pos += 2
		mut node := p.conditional()
		p.expect(')')
		return p.new_num(i64(int(is_const_expr(mut node))), tok)
	}
	// `va_start` and `va_end` are statements in practice: C spells them as macros, and
	// every use of them is one. Emitting them as expressions that leave a value on the
	// stack is not a technicality — the generator counts the values a function leaves
	// behind and reports `left N values on the stack` when it is not zero, so a
	// perfectly correct `va_start(ap, n);` would fail to compile for being in the
	// wrong syntactic form.
	//
	// `p.tok_at(1)` is the `(`: without it these are identifiers, and `identifier;`
	// is an ordinary expression statement, which is exactly what must not happen here.
	if p.at('__builtin_va_start') || p.at('__builtin_va_end') {
		if p.tok_at(1).text == '(' {
			return p.builtin_va_stmt()
		}
	}
	if va := p.builtin_va(tok) {
		return va
	}

	if tok.text == '_Generic' {
		p.pos++
		return p.generic_selection()
	}

	if tok.kind == .ident {
		sc := p.find_var(tok.text)
		p.pos++
		if sc != none {
			entry := sc
			if entry.obj != unsafe { nil } {
				return p.new_var_node(entry.obj, tok)
			}
			if entry.enum_ty != unsafe { nil } {
				// An enumeration constant has type int, and it is given one here rather
				// than left for `add_type` to derive from the spelling — the spelling is an
				// identifier, and deriving a numeric type from an identifier's letters is
				// how `NEG` came out as a double and evaluated to zero.
				return &ast.Node{
					kind: .num
					tok:  tok
					num:  entry.enum_val
					ty:   ty_int
				}
			}
		}
		if p.at('(') {
			// C89 let a function be used before it was declared, and V's headers rely
			// on it — `time.h` calls `_gmtime64_s` having declared only `_gmtime64`.
			//
			// A *warning*, not an error, and that is measured rather than assumed: tcc
			// prints `implicit declaration of function '_gmtime64_s'` and exits 0, and gcc
			// treats it as gnu11's implicit-declaration warning too. Reporting it as an
			// error made `time.h` uncompilable, and the return type is still a guess, so
			// the warning is what carries the risk without refusing the program.
			p.warn_at(tok, 'implicit declaration of function "${tok.text}"')
			// The declaration is invented so the call has a type to be checked against.
			// It returns `int` and is variadic, which is the C89 assumption, and it is
			// not marked as a definition so nothing is emitted for it.
			mut ty := func_type(ty_int)
			ty.params = []&ast.Type{}
			ty.is_variadic = true
			mut obj := p.new_gvar(tok.text, ty, tok.line.disp_line)
			obj.is_function = true
			obj.is_definition = false
			obj.is_static = false
			return p.new_var_node(obj, tok)
		}
		p.error_at_help(tok, 'undefined variable "${tok.text}"', 'it was never declared in this scope — check the spelling against its declaration')
		return p.unsupported_expression()
	}

	if tok.kind == .str_ {
		return p.string_literal_expr()
	}
	if tok.kind == .num_ {
		p.pos++
		ty := numeric_type(&tok)
		// An invalid pp-number is a diagnostic, not a value. This is the only site with
		// both the token and an error channel: `numeric_type` is a free function that
		// returns a type on every path, and the value was already decoded in the
		// tokenizer — so reporting here cannot disturb the value path, and it is what
		// stops `0zz` from silently becoming an int 0.
		//
		// A character constant is a `.num_` token too, and its text is the spelling *with
		// the quotes on* — `'a'`. Validating that would report a char literal as a bad
		// number, which is what happened the first time this was written. The same guard
		// `numeric_type` uses is applied first, for the same reason.
		if tok.text.len > 0 && is_number_start(tok.text[0]) {
			bad := invalid_numeric_suffix(tok.text)
			if bad != '' {
		kind := if is_flonum(ty) { 'floating' } else { 'integer' }
		p.error_at_help(tok, "invalid suffix '${bad}' on ${kind} constant", 'integer suffixes are u/U, l/L and ll/LL; floating suffixes are f/F and l/L')
			}
		}
		if is_flonum(ty) {
			return &ast.Node{
				kind: .num
				tok:  tok
				fval: tok.fval
				ty:   ty
			}
		}
		return &ast.Node{
			kind: .num
			tok:  tok
			num:  tok.val
			ty:   ty
		}
	}

	p.error_at(tok, 'expected an expression')
	return p.unsupported_expression()
}

// builtin_va_stmt parses `va_start(ap, last)` and `va_end(ap)` as the statements they
// are, and returns a `.null_stmt` so the generator emits nothing for them.
//
// They are statements rather than expressions because of what they *do*, not how they
// are spelled. `va_start` is a single store and `va_end` is nothing at all: neither
// produces a value, and this generator's contract is that every expression leaves
// exactly one eight-byte slot on the stack, checked at the end of every function.
// Implementing them as expressions made `vcc` refuse to compile a correct
// `va_start(ap, n);` with `function "sum6" left 1 values on the stack` — a diagnostic
// that names the stack rather than the construct that caused it.
//
// `va_arg` and `va_copy` are the opposite: `va_arg` is an rvalue and `va_copy` is
// conventionally written as a statement but is an assignment, so both stay in
// `builtin_va`.
fn (mut p Parser) builtin_va_stmt() &ast.Node {
	tok := p.tok()
	p.pos += 2 // the builtin and the `(`

	if tok.text == '__builtin_va_start' {
		ap := p.assign()
		p.expect(',')
		// [C11 7.16.1.4] `va_start(ap, last)`, and the second operand is unused: it
		// exists so a macro can name the parameter before `...`. Where the walk begins
		// follows from the *named* parameters, which is a frame-layout question, and
		// `assign_lvar_offsets` answers it. The operand is still parsed, because leaving
		// its tokens unconsumed puts the *next* statement's diagnostic in the wrong place.
		p.assign()
		p.expect(')')
		return p.new_unary(.va_start_, ap, tok)
	}

	// `va_end`
	p.assign()
	p.expect(')')
	return p.new_node(.null_stmt, tok)
}

// builtin_va parses the four `__builtin_va_*` operations and returns none for anything
// else.
//
// The `<stdarg.h>` on this target is the whole of the mechanism:
//
//	typedef __builtin_va_list va_list;
//	#define va_start __builtin_va_start
//	#define va_arg   __builtin_va_arg
//	#define va_copy  __builtin_va_copy
//	#define va_end   __builtin_va_end
//
// so these four names are what a vcc program actually has to support to read a
// variadic argument at all, and `<stdarg.h>` is on the include path V passes.
//
// They are parsed here rather than in the backend because `va_arg`'s second operand
// is a *type*, which is known at compile time, so the whole offset computation folds
// to a constant stride. A backend would need an instruction-encoder-visible special
// case for a construct that has no run-time shape of its own.
//
// All four go in together. A variadic callee that reads integers correctly and
// floats wrongly is much harder to diagnose than one that refuses, because the
// failure is a wrong number rather than an error.
fn (mut p Parser) builtin_va(tok ast.Token) ?&ast.Node {
	match tok.text {
		'__builtin_va_start' {
			// As a *value* rather than a statement. Nothing in C needs this and the
			// generator would reject it for leaving a value behind, so it is reported
			// rather than quietly accepted — see `builtin_va_stmt`, which is the path
			// every real use takes.
			p.pos += 2
			p.assign()
			p.expect(',')
			p.assign()
			p.expect(')')
			p.error_at(tok, 'va_start is a statement and has no value')
			return p.new_node(.null_expr, tok)
		}
		'__builtin_va_arg' {
			p.pos += 2
			ap := p.assign()
			p.expect(',')
			ty := p.typename()
			p.expect(')')
			mut node := p.new_binary(.va_arg_, ap, p.new_size_t(0, tok), tok)
			node.ty = ty
			return node
		}
		'__builtin_va_copy' {
			p.pos += 2
			dst := p.assign()
			p.expect(',')
			src := p.assign()
			p.expect(')')
			// The two are pointers, so this is an ordinary eight-byte copy. That is the
			// whole of `va_copy` on this target, and it is why the tag is not a struct:
			// see `src/ast/abi.v`.
			mut node := p.new_binary(.assign, dst, src, tok)
			add_type(mut node)
			return node
		}
		'__builtin_va_end' {
			p.pos += 2
			p.assign()
			p.expect(')')
			// [C11 7.16.1.4] `va_end` makes the `va_list` unusable and says nothing about
			// how. On this target there is nothing to release: the pointer is the caller's
			// own storage and the register area is the frame. So this is a `void` no-op.
			return p.new_node(.null_expr, tok)
		}
		else {
			return none
		}
	}
}

// unsupported_expression consumes tokens up to something that can end an expression
// and returns a `.generic` node standing in for what it did not understand.
//
// Consuming rather than stopping is what lets the corpus sweep see every construct
// vcc cannot yet parse instead of only the first one in the file.
// unsupported_expression skips an expression this front end does not implement and
// stands a zero in its place.
//
// The stand-in is typed. It used to be an untyped `.generic` node, and an untyped node
// reaches `add_type`, which reads `node.then.ty` and crashes on the nil — so a
// construct that was merely *unimplemented* aborted the compiler instead of being
// reported. `a ?: b` did exactly that.
fn (mut p Parser) unsupported_expression() &ast.Node {
	tok := p.tok()
	mut depth := 0
	for p.tok().kind != .eof {
		if p.at('(') || p.at('[') || p.at('{') {
			depth++
		} else if p.at(')') || p.at(']') {
			if depth == 0 {
				break
			}
			depth--
		} else if p.at('}') {
			break
		} else if depth == 0 && (p.at(',') || p.at(';') || p.is_end()) {
			break
		}
		p.pos++
	}
	return &ast.Node{
		kind: .num
		tok:  tok
		num:  0
		ty:   ty_int
	}
}

// size_of_type returns `sizeof` of a type.
//
// A variable-length array's size is a run-time value held in a local the type records,
// so the answer is either a read of that local or, for a type name that has never been
// declared, the expression that computes it.
//
// Three shapes, and only the first is a constant:
//
//	sizeof(int[5])      array of a fixed type       -> a number
//	sizeof(char[n])     a VLA                       -> n
//	sizeof(char[2][n])  an array of a VLA           -> 2 * n
//
// The third is the one that used to be wrong in two directions at once. An array whose
// element is a VLA has a constant *length* and a run-time *element*, so its size is
// neither: it answered `array_len * 8`, the placeholder width `vla_of` gives a VLA, which
// is 40 for `int[n][5]` where the answer is 60. And a bare VLA fell through to an untyped
// `.generic` node, which the backend reached as `gen_binary` with a nil left operand and
// reported as `operator with no left operand at line 22` — a diagnostic naming the
// arithmetic rather than the type name that could not be sized.
fn (mut p Parser) size_of_type(ty &ast.Type, tok ast.Token) &ast.Node {
	if ty.kind == .vla {
		// A declared VLA already has its size local, and computing a second one would
		// mean `sizeof(x)` evaluated the extent expression a second time.
		if ty.vla_size != unsafe { nil } {
			return p.new_var_node(ty.vla_size, tok)
		}
		mut fresh := ty
		return p.compute_vla_size(mut fresh, tok)
	}
	if ty.kind == .array && ty.base != unsafe { nil } && ty.base.kind == .vla {
		mut base := ty.base
		// `compute_vla_size` assigns the element's size to a local of its own and
		// yields it, so the product reads that local rather than running the extent
		// expression twice.
		sized := p.compute_vla_size(mut base, tok)
		mut product := p.new_binary(.mul, p.new_var_node(base.vla_size, tok),
			p.new_num(i64(ty.array_len), tok), tok)
		mut node := p.new_binary(.comma, sized, product, tok)
		add_type(mut node)
		return node
	}
	return p.new_size_t(i64(ty.size), tok)
}

// pointee_size returns the expression giving the size of what a pointer points at.
//
// A pointer to a variable-length array steps by the array's *run-time* size, which the
// declaration already computed into a local of its own. The type's `size` is not it:
// `vla_of` gives every VLA a placeholder of eight bytes, because the extent is not known
// until the declaration runs.
//
// So for `int x[n + 1][n + 6]`, `x[i]` steps by `sizeof(int[n + 6])` — a read of the
// inner VLA's size local — and not by eight. Scaling by the placeholder is what made
// `x[1][0]` return the second element of the first row rather than the first element of
// the second: measured against tcc, `x[1][0]` was 2 where it must be 16.
fn (mut p Parser) pointee_size(ty &ast.Type, tok ast.Token) &ast.Node {
	base := ty.base
	if base != unsafe { nil } && base.kind == .vla && base.vla_size != unsafe { nil } {
		return p.new_var_node(base.vla_size, tok)
	}
	return p.new_num(i64(base.size), tok)
}

// new_sub builds `lhs - rhs`, scaling by the pointee's size when the left side is a
// pointer. `int - pointer` is left to `add_type` to reject, because it is a type error
// rather than an arithmetic one.
//
// When both sides are pointers, C11 6.5.6p9 requires the byte difference divided
// by the element size, with type `ptrdiff_t` — which is `long long` on this
// target, measured from tcc and gcc. Without the division `&x[1] - &x[0]` answers
// 4 for an `int` array, and the symptom is a wrong comparison two statements
// later rather than anything at the subtraction itself.
fn (mut p Parser) new_sub(mut lhs &ast.Node, mut rhs &ast.Node, tok ast.Token) &ast.Node {
	add_type(mut lhs)
	add_type(mut rhs)
	mut node := p.new_binary(.sub, lhs, rhs, tok)
	if lhs.ty.base != unsafe { nil } && rhs.ty.base != unsafe { nil } {
		mut scaled := p.new_binary(.div, node, p.pointee_size(lhs.ty, tok), tok)
		add_type(mut scaled)
		scaled.ty = ty_llong
		return scaled
	}
	if lhs.ty.base != unsafe { nil } && rhs.ty.base == unsafe { nil } {
		mut scaled := p.new_binary(.mul, rhs, p.pointee_size(lhs.ty, tok), tok)
		add_type(mut scaled)
		node.rhs = scaled
	}
	add_type(mut node)
	return node
}

// new_add builds `lhs + rhs`, scaling by the pointee's size when either side is a
// pointer, which is what makes `p + 1` advance by one element.
fn (mut p Parser) new_add(mut lhs &ast.Node, mut rhs &ast.Node, tok ast.Token) &ast.Node {
	add_type(mut lhs)
	add_type(mut rhs)
	mut node := &ast.Node{
		kind: .add
		tok:  tok
		lhs:  lhs
		rhs:  rhs
	}
	if lhs.ty.base != unsafe { nil } && rhs.ty.base == unsafe { nil } {
		// ptr + int
		mut scaled := p.new_binary(.mul, rhs, p.pointee_size(lhs.ty, tok), tok)
		add_type(mut scaled)
		node.rhs = scaled
	} else if lhs.ty.base == unsafe { nil } && rhs.ty.base != unsafe { nil } {
		// int + ptr
		mut scaled := p.new_binary(.mul, lhs, p.pointee_size(rhs.ty, tok), tok)
		add_type(mut scaled)
		node.lhs = scaled
		node.rhs = rhs
	}
	add_type(mut node)
	return node
}
