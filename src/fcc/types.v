module fcc
import ast

// The type system.
//
// Everything here is a function of another type: nothing needs a central table,
// because a C type is built one constructor at a time. The one thing that *is* a
// table is the set of basic types, and that table is measured rather than
// assumed — see the note on the layout table and D20 in notes/DECISIONS.md.

// --- the measured layout table ---
//
// Every size and alignment below was read off the bundled tcc
// (0.9.28rc, x86-64 Windows) with a probe program, because vcc has to agree with
// the objects tcc has already produced (`libgc.a`, `libtcc1.a`) and with V's own
// generated C. Two of these differ from chibicc's table, which describes System V:
//
//	long		4 / 4   (chibicc: 8 / 8)
//	long double	8 / 8   (chibicc: 16 / 16)
//
// `long` being 4 bytes is the Windows ABI, and also what MSVC does, so matching it
// keeps V's objects compatible with more than tcc's. `long double` being 8 bytes
// is tcc treating it as `double`, which is what MSVC does too.
//
// Using chibicc's numbers here would not fail loudly. It would make every `long`
// field in every V-generated struct the wrong width, and the symptom would
// surface as corrupted data somewhere unrelated.

// max_int32 is the largest value an unsuffixed decimal constant can hold before
// it has to be something wider than int.
const max_int32 = 0x7fffffff

// ty_void has size 1 rather than 0 because GNU C defines `sizeof(void)` as 1, and
// both tcc and the headers rely on that for `void *` arithmetic.
pub const ty_void = &ast.Type{ kind: .basic, basic: .void_, size: 1, align: 1 }
pub const ty_bool = &ast.Type{ kind: .basic, basic: .bool_, size: 1, align: 1 }
pub const ty_char = &ast.Type{ kind: .basic, basic: .char_, size: 1, align: 1 }
pub const ty_short = &ast.Type{ kind: .basic, basic: .short_, size: 2, align: 2 }
pub const ty_int = &ast.Type{ kind: .basic, basic: .int_, size: 4, align: 4 }
// ty_long is 4 bytes here, so `long` and `int` are the same width. They are still
// different types: `long long` is 8 bytes and the usual arithmetic conversions
// distinguish them.
pub const ty_long = &ast.Type{ kind: .basic, basic: .long_, size: 4, align: 4 }
pub const ty_llong = &ast.Type{ kind: .basic, basic: .llong_, size: 8, align: 8 }
pub const ty_uchar = &ast.Type{ kind: .basic, basic: .char_, size: 1, align: 1, is_unsigned: true }
pub const ty_ushort = &ast.Type{ kind: .basic, basic: .short_, size: 2, align: 2, is_unsigned: true }
pub const ty_uint = &ast.Type{ kind: .basic, basic: .int_, size: 4, align: 4, is_unsigned: true }
pub const ty_ulong = &ast.Type{ kind: .basic, basic: .long_, size: 4, align: 4, is_unsigned: true }
pub const ty_ullong = &ast.Type{ kind: .basic, basic: .llong_, size: 8, align: 8, is_unsigned: true }
pub const ty_float = &ast.Type{ kind: .basic, basic: .float_, size: 4, align: 4 }
pub const ty_double = &ast.Type{ kind: .basic, basic: .double_, size: 8, align: 8 }
pub const ty_ldouble = &ast.Type{ kind: .basic, basic: .ldouble_, size: 8, align: 8 }

// ty_size_t is what `sizeof` and `_Alignof` evaluate to.
//
// It is an unsigned long long because `size_t` is 8 bytes on this target, measured.
// chibicc returns an unsigned long, which is 4 bytes here: a `sizeof` result would
// then be a 32-bit value that silently truncates for any type over 4GB, and every
// comparison against a real `size_t` would be a comparison of two different widths.
pub const ty_size_t = ty_ullong

// ty_va_list is what `__builtin_va_list` names, and it is `char *`.
//
// Measured on this host rather than assumed: both compilers report
// `sizeof(va_list) == 8`, and dumping the bytes a callee's `va_list` points at
// shows the argument values themselves, not a `gp_offset`/`fp_offset` header. So
// it is a pointer, and `src/ast/abi.v` records the layout it walks.
//
// `char *` rather than `void *` because the pointer is dereferenced by `va_arg`
// through a cast to whatever type is asked for, and `char` is what makes the
// arithmetic on it well defined in C.
pub fn ty_va_list() &ast.Type {
	return pointer_to(ty_char)
}

// align_to rounds n up to a multiple of align. It divides rather than masking, so
// it works for negative n as well, which align_down depends on.
pub fn align_to(n int, align int) int {
	return (n + align - 1) / align * align
}

// align_down rounds n down to a multiple of align.
//
// The `- align + 1` is what makes it correct for a value that is not already a
// multiple: aligning `n - align + 1` lands on the same multiple as aligning `n`
// for every n >= 1. Bitfield storage-unit offsets need this rather than a plain
// division, because a field that starts partway into a byte still belongs to the
// unit below it.
pub fn align_down(n int, align int) int {
	return align_to(n - align + 1, align)
}

// new_type returns a type of the given kind with a known size.
fn new_type(kind ast.TypeKind, basic ast.Basic, size int, align int) &ast.Type {
	return &ast.Type{
		kind:  kind
		basic: basic
		size:  size
		align: align
	}
}

pub fn is_integer(ty &ast.Type) bool {
	return match ty.kind {
		.basic { ty.basic in [.bool_, .char_, .short_, .int_, .long_, .llong_] }
		.enum_ { true }
		else { false }
	}
}

pub fn is_flonum(ty &ast.Type) bool {
	return ty.kind == .basic && ty.basic in [.float_, .double_, .ldouble_]
}

pub fn is_numeric(ty &ast.Type) bool {
	return is_integer(ty) || is_flonum(ty)
}

// copy_type returns a type equal to ty but with its own identity.
//
// The copy records ty as its origin, which is what makes compatibility checking
// work: two types are compatible when they can be traced back to a common one, so
// a typedef and the type it names compare equal without walking their structure.
//
// It also lets a declarator attach a name to the copy rather than to a shared
// type. That matters because the basic types above are `const`: writing a name
// onto one of those would be a runtime panic, which is the failure mode this
// indirection exists to prevent.
pub fn copy_type(ty &ast.Type) &ast.Type {
	mut c := *ty
	c.origin = ty
	return &c
}

pub fn pointer_to(base &ast.Type) &ast.Type {
	mut ty := new_type(.pointer, .none, 8, 8)
	ty.base = base
	// A pointer is unsigned because pointer comparison is unsigned. That is what
	// tcc and gcc both do, and a signed comparison of two pointers is a bug that
	// only appears once an address passes 2GB.
	ty.is_unsigned = true
	return ty
}

// func_type returns `ret_ty()`. The size and alignment are 1 because C forbids
// `sizeof` of a function type, and 1 is what both gcc and tcc answer.
pub fn func_type(ret_ty &ast.Type) &ast.Type {
	mut ty := new_type(.func, .none, 1, 1)
	ty.ret_type = ret_ty
	return ty
}

// array_of returns `base[len]`, where a negative length means the length is not
// known yet.
pub fn array_of(base &ast.Type, len int) &ast.Type {
	mut ty := new_type(.array, .none, if len < 0 { -1 } else { base.size * len },
		base.align)
	ty.base = base
	ty.array_len = len
	return ty
}

// vla_of returns `base[len]` where len is only known at run time.
pub fn vla_of(base &ast.Type, len &ast.Node) &ast.Type {
	mut ty := new_type(.vla, .none, 8, 8)
	ty.base = base
	ty.vla_len = len
	ty.array_len = -1
	return ty
}

pub fn enum_type() &ast.Type {
	return new_type(.enum_, .enum_, 4, 4)
}

// struct_type returns an empty struct type, which is what a tag named before its
// body refers to. A size of 0 is a real C type — `struct {}` — which is why an
// incomplete type is -1 rather than 0.
pub fn struct_type() &ast.Type {
	return new_type(.struct_, .none, 0, 1)
}

pub fn union_type() &ast.Type {
	return new_type(.union_, .none, 0, 1)
}

// is_compatible reports whether two types may be used interchangeably.
//
// The origin chase is what makes a typedef transparent. Without it, a function
// declared through a typedef and defined through the underlying type would look
// like two different functions.
pub fn is_compatible(t1 &ast.Type, t2 &ast.Type) bool {
	if t1 == t2 {
		return true
	}
	if t1.origin != unsafe { nil } {
		return is_compatible(t1.origin, t2)
	}
	if t2.origin != unsafe { nil } {
		return is_compatible(t1, t2.origin)
	}
	if t1.kind != t2.kind {
		return false
	}
	match t1.kind {
		.basic {
			// The three floating types are one class; every other basic type is only
			// compatible with itself and with the same signedness. `is_flonum(t1)` alone
			// is not enough, because `kind` is `.basic` for all of them and the basic
			// itself has to be compared — which is what made `_Generic(n, int: 1,
			// double: 2)` with an `int` controlling expression pick the `double`.
			if is_flonum(t1) {
				return is_flonum(t2)
			}
			if is_flonum(t2) {
				return false
			}
			return t1.basic == t2.basic && t1.is_unsigned == t2.is_unsigned
		}
		.pointer { return is_compatible(t1.base, t2.base) }
		.func {
			if !is_compatible(t1.ret_type, t2.ret_type) {
				return false
			}
			if t1.is_variadic != t2.is_variadic {
				return false
			}
			if t1.params.len != t2.params.len {
				return false
			}
			for i, p in t1.params {
				if !is_compatible(p, t2.params[i]) {
					return false
				}
			}
			return true
		}
		.array {
			if !is_compatible(t1.base, t2.base) {
				return false
			}
			// An array of unknown length is compatible with any array of the same
			// element type, which is what lets `int x[]` be completed by its
			// initializer.
			return t1.array_len < 0 || t2.array_len < 0 || t1.array_len == t2.array_len
		}
		else { return false }
	}
}

// is_exact_type_match reports whether two types are the same type, which is what
// [C11 6.5.1.1p2] requires for a generic selection: the controlling expression's type
// is compared against each association's type, and only an exact match selects.
//
// The difference from is_compatible is that the three floating types are distinct:
// `double` is not `float`, so `_Generic(100.0, double: 1, float: 4)` selects the
// `double` association. is_compatible treats them as one class, which is correct for
// assignment and function calls but wrong here.
pub fn is_exact_type_match(t1 &ast.Type, t2 &ast.Type) bool {
	if t1 == t2 {
		return true
	}
	if t1.origin != unsafe { nil } {
		return is_exact_type_match(t1.origin, t2)
	}
	if t2.origin != unsafe { nil } {
		return is_exact_type_match(t1, t2.origin)
	}
	if t1.kind != t2.kind {
		return false
	}
	match t1.kind {
		.basic {
			if is_flonum(t1) || is_flonum(t2) {
				return t1.basic == t2.basic
			}
			return t1.basic == t2.basic && t1.is_unsigned == t2.is_unsigned
		}
		.pointer { return is_exact_type_match(t1.base, t2.base) }
		.func {
			if !is_exact_type_match(t1.ret_type, t2.ret_type) {
				return false
			}
			if t1.is_variadic != t2.is_variadic {
				return false
			}
			if t1.params.len != t2.params.len {
				return false
			}
			for i, p in t1.params {
				if !is_exact_type_match(p, t2.params[i]) {
					return false
				}
			}
			return true
		}
		.array {
			if !is_exact_type_match(t1.base, t2.base) {
				return false
			}
			return t1.array_len < 0 || t2.array_len < 0 || t1.array_len == t2.array_len
		}
		else { return false }
	}
}

// get_common_type returns the type both operands of a binary operator become.
fn get_common_type(ty1 &ast.Type, ty2 &ast.Type) &ast.Type {
	// An array or a function decays to a pointer in every arithmetic context, and
	// C's rule is that it is the *element* type that matters, so an array of
	// arrays does not become a pointer to an array here.
	if ty1.base != unsafe { nil } {
		return pointer_to(ty1.base)
	}
	if ty1.kind == .func {
		return pointer_to(ty1)
	}
	if ty2.kind == .func {
		return pointer_to(ty2)
	}
	if ty1.basic == .ldouble_ || ty2.basic == .ldouble_ {
		return ty_ldouble
	}
	if ty1.basic == .double_ || ty2.basic == .double_ {
		return ty_double
	}
	if ty1.basic == .float_ || ty2.basic == .float_ {
		return ty_float
	}
	// Anything narrower than int is promoted to int first: that is the integer
	// promotion rule, and it is why `char + char` is an int addition.
	a := if ty1.size < 4 { ty_int } else { ty1 }
	b := if ty2.size < 4 { ty_int } else { ty2 }
	if a.size != b.size {
		return if a.size < b.size { b } else { a }
	}
	if b.is_unsigned {
		return b
	}
	return a
}

// usual_arith_conv promotes both operands of a binary operator to one type.
//
// Anything narrower than int becomes int first, which is the integer promotion
// rule and the reason `(char)x + (char)y` cannot overflow at 8 bits.
fn usual_arith_conv(mut node &ast.Node) {
	ty := get_common_type(node.lhs.ty, node.rhs.ty)
	node.lhs = new_cast(node.lhs, ty)
	node.rhs = new_cast(node.rhs, ty)
}

// new_cast wraps expr in a conversion to ty.
pub fn new_cast(expr &ast.Node, ty &ast.Type) &ast.Node {
	// The local is a second name for the same node, which is what lets `mut` be
	// satisfied here instead of on every caller.
	if expr != unsafe { nil } {
		mut e := expr
		add_type(mut e)
	}
	return &ast.Node{
		kind: .cast
		tok:  expr.tok
		lhs:  expr
		ty:   copy_type(ty)
	}
}

// type_child types one child of a node, tolerating its absence.
//
// A node walks every field it has whether or not its kind uses it, so the nil
// check belongs here rather than at each of the seven call sites. The local `mut`
// binding is the second name for the same node: `add_type` needs a mutable
// reference, and asking the caller for one would put `mut` at every call site for
// a function that only reads the reference.
fn type_child(n &ast.Node) {
	if n != unsafe { nil } {
		mut e := n
		add_type(mut e)
	}
}

// add_type fills in node.ty, and the types of everything node contains.
//
// It is idempotent: a node that already has a type is left alone, so the parser can
// call it whenever it needs a type without paying for a second walk.
//
// It is a free function rather than a method because this V build does not resolve
// a method on an imported `@[heap]` struct at all — `expr.add_type()` reports
// "unknown function" for every receiver spelling it accepts, which cost a cycle to
// establish. The price is `mut` at each call site, which V requires and which says
// nothing about the caller's intent.
pub fn add_type(mut node &ast.Node) {
	if node.ty != unsafe { nil } {
		return
	}
	type_child(node.lhs)
	type_child(node.rhs)
	type_child(node.cond)
	type_child(node.then)
	type_child(node.els)
	type_child(node.init)
	type_child(node.inc)
	for n in node.body {
		type_child(n)
	}
	for a in node.args {
		type_child(a)
	}

	match node.kind {
		.num { node.ty = numeric_type(node.tok) }
		.add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor {
			usual_arith_conv(mut node)
			node.ty = node.lhs.ty
		}
		.neg {
			ty := get_common_type(ty_int, node.lhs.ty)
			node.lhs = new_cast(node.lhs, ty)
			node.ty = ty
		}
		.assign {
			// [C11 6.5.16.1] The value stored is "the value of the right operand
			// converted to the type of the assignment expression", which is the type of
			// the left operand. The conversion is not optional: it is the difference
			// between storing a number and storing the *representation* the left type
			// calls for.
			//
			// Without it, `double s = 0;` stored an integer zero through an SSE store.
			// `gen_num` left the value in `%rax` — an integer register — and `store`
			// wrote `%xmm0`, which nothing had loaded, so the slot kept whatever the
			// frame held. Measured: a program doing only
			//
			//	double s = 0; s += 1.5; s += 2.5; s += 3.0; return s;
			//
			// returned 3.7756e+150 under vcc and 7 under both gcc and tcc. It is
			// pre-existing rather than anything to do with variadic arguments: the same
			// program has no `va_arg` in it, and it fails identically on a build of the
			// commit before this work.
			//
			// `usual_arith_conv` is the wrong thing to reach for here: it picks *one*
			// common type for both operands, and the left operand's type is fixed — it
			// is the object being stored into. So the right operand is cast to the left
			// operand's type, not to a common type.
			mut target := node.lhs
			add_type(mut target)
			mut rhs := node.rhs
			add_type(mut rhs)
			if target.ty != unsafe { nil } && rhs.ty != unsafe { nil }
				&& !is_compatible(target.ty, rhs.ty) {
				node.rhs = new_cast(node.rhs, target.ty)
			}
			node.ty = target.ty
		}
		.eq, .ne, .lt, .le {
			usual_arith_conv(mut node)
			node.ty = ty_int
		}
		.funcall { node.ty = node.func_ty.ret_type }
		.not, .log_or, .log_and { node.ty = ty_int }
		.bit_not, .shl, .shr { node.ty = node.lhs.ty }
		.var_ref { node.ty = node.var.ty }
		// A `.vla_ptr` reads as the *pointer* the array was allocated into, not as the
		// array: its frame slot holds a `T *`, and that pointer is the value an
		// expression using the array decays to. Giving it the `.vla` type would make
		// `load` treat it as an aggregate and hand back the slot's own address.
		.vla_ptr { node.ty = pointer_to(node.var.ty.base) }
		.cond_expr {
			if node.then.ty.basic == .void_ || node.els.ty.basic == .void_ {
				node.ty = ty_void
			} else {
				// The two branches are the operands here, not `lhs` and `rhs`. A
				// conditional is the one expression whose operands are not in those
				// fields, which is exactly the sort of thing that reads as a copy of the
				// binary case and crashes on a nil.
				ty := get_common_type(node.then.ty, node.els.ty)
				node.then = new_cast(node.then, ty)
				node.els = new_cast(node.els, ty)
				node.ty = ty
			}
		}
		.comma { node.ty = node.rhs.ty }
		.member {
			m := node.member or { return }
			node.ty = m.ty
		}
		.addr {
			// `&arr` is a pointer to the first element, not to the array. For every
			// other type it is a pointer to the object itself.
			mut elem := node.lhs.ty
			if elem.kind == .array {
				elem = elem.base
			}
			node.ty = pointer_to(elem)
		}
		.deref { node.ty = node.lhs.ty.base }
		.stmt_expr {
			if node.body.len == 0 || node.body.last().kind != .expr_stmt {
				node.ty = ty_void
			} else {
				node.ty = node.body.last().lhs.ty
			}
		}
		else {}
	}
}

// numeric_type returns the type a numeric literal has.
//
// The type is derived from the spelling here rather than recorded by the tokenizer,
// because C's rules depend on the base and the suffix together — `0x1F` is the
// int 31 while `0x1f` is a float — and one place that knows the rule keeps it out
// of the lexer's hot path.
//
// The promotions implemented here are the ones this target needs. In particular an
// unsuffixed decimal that does not fit an int becomes a long long, not a long,
// because a long on this target is the same width as an int.
pub fn numeric_type(tok &ast.Token) &ast.Type {
	// A prefixed *character* constant is a `wchar_t`, `char16_t` or `char32_t` and
	// nothing else, so its prefix answers the question outright. It has to be asked
	// before the guard below, which would otherwise reject the token for not starting
	// with a digit and hand back `int` — four bytes, where this target measures two for
	// both `L` and `u`.
	//
	// Only a character constant reaches here with a prefix: a prefixed *string* is a
	// `str_` token and is typed by `string_literal_type` instead. This is not a hot
	// path, so one extra map-free comparison on every numeric literal is the cheap
	// version of keeping the two apart.
	if wide := wide_literal_type(tok) {
		return wide
	}
	// A token whose spelling does not begin like a number is not one. This guard is
	// there because a type derived from the wrong token is a wrong answer rather than
	// an error: an enumeration constant's spelling is an identifier, and `NEG` contains
	// an `E`.
	if tok.kind != .num_ || tok.text.len == 0 || !is_number_start(tok.text[0]) {
		return ty_int
	}
	suffix := numeric_suffix(tok.text)
	if suffix.contains('f') || suffix.contains('F') {
		return ty_float
	}
	// A hexadecimal float always carries a `p` exponent, and an unsuffixed
	// floating constant of any other base is a double.
	if is_hex_float(tok.text) || is_float_spelling(tok.text) {
		return ty_double
	}
	unsigned := suffix.contains('u') || suffix.contains('U')
	// `ll` is two letters, so counting them is what distinguishes `1l` from `1ll`.
	wide := count_byte(suffix, `l`) >= 2 || count_byte(suffix, `L`) >= 2
	mut ty := ty_int
	if wide {
		ty = ty_llong
	} else if suffix.contains('l') || suffix.contains('L') {
		ty = ty_long
	}
	if unsigned {
		return unsigned_version(ty)
	}
	if tok.val <= i64(max_int32) {
		return ty
	}
	// A constant written in a base other than ten may be written to mean an
	// unsigned type without saying so; a decimal one may not.
	return if is_nondecimal(tok.text) { ty_uint } else { ty_llong }
}

// numeric_suffix returns the type suffix of a literal's spelling.
//
// It is the part `strip_numeric_suffix` removes, found by difference rather than by
// a second set of rules, so the two cannot disagree about where the digits stop.
pub fn numeric_suffix(text string) string {
	return text[strip_numeric_suffix(text).len..]
}

// unsigned_version returns the unsigned type of the same width as ty.
fn unsigned_version(ty &ast.Type) &ast.Type {
	return match ty.basic {
		.char_ { ty_uchar }
		.short_ { ty_ushort }
		.long_ { ty_ulong }
		.llong_ { ty_ullong }
		else { ty_uint }
	}
}

// is_number_start reports whether a byte can begin a numeric literal.
fn is_number_start(c u8) bool {
	return c >= `0` && c <= `9`
}

// is_hex_float reports whether a literal is a hexadecimal float, which is
// identified by its `p` exponent.
fn is_hex_float(text string) bool {
	return text.contains('p') || text.contains('P')
}

// is_float_spelling reports whether a literal has a `.` or a decimal exponent.
// Hexadecimal literals are excluded, because there `.` and `e` mean something else
// and `is_hex_float` has already answered for them.
fn is_float_spelling(text string) bool {
	if is_nondecimal(text) && text.len > 1 && (text[1] == `x` || text[1] == `X`) {
		return false
	}
	return text.contains('.') || text.contains('e') || text.contains('E')
}

// is_nondecimal reports whether a literal is written in a base other than ten,
// which is what lets `0xFFFFFFFF` be an unsigned int with no `u` suffix.
fn is_nondecimal(text string) bool {
	if text.len < 2 || text[0] != `0` {
		return false
	}
	return text[1] == `x` || text[1] == `X` || text[1] == `b` || text[1] == `B`
}

fn count_byte(s string, c u8) int {
	mut n := 0
	for x in s {
		if x == c {
			n++
		}
	}
	return n
}

// string_literal_type returns the array type a string literal has, including the
// terminating NUL.
//
// The element count is a count of code points, not of bytes: `str_data` holds UTF-8,
// and `L"ab"` is three two-byte elements rather than one. Dividing the byte length by
// the element size would give 1 there, which is how this was wrong the first time.
pub fn string_literal_type(tok &ast.Token) &ast.Type {
	elem := string_element_type(tok)
	return array_of(elem, code_point_count(tok.str_data) + 1)
}

// string_element_type returns the type one element of a string literal has, which its
// prefix decides.
//
// The widths are measured, not carried over from chibicc. chibicc is System V, where
// `wchar_t` is four bytes; on this target it is two, and so is `char16_t`.
pub fn string_element_type(tok &ast.Token) &ast.Type {
	return wide_literal_type(tok) or { ty_char }
}

// wide_literal_type returns the type a prefixed literal's element has, or none for an
// unprefixed one — which is `char`.
//
// Measured on this host for a three-character literal, tcc and mingw gcc 15.2
// answering identically where tcc can answer at all:
//
//	 L"ab"   =  6   ->  2 bytes   wchar_t
//	 u"ab"   =  6   ->  2 bytes   char16_t
//	 U"ab"   = 12   ->  4 bytes   char32_t
//	 u8"ab"  =  3   ->  1
//	 "ab"    =  3   ->  1
//	L'a'     =  2
//	u'a'     =  2
//	U'a'     =  4
//
// tcc rejects `u"` and `U"` outright and does not know `u8"` either, so those three are
// gcc's answer alone. It is also what C11 6.4.4.4 says, and it agrees with `U` being
// four here, which is the one width this target does *not* differ from Linux on.
//
// This was four bytes for every prefix, and the consequence was worse than a wrong
// `sizeof`: the storage image was already written at the correct stride, because
// `string_initializer` takes the element width from the *declared* array rather than
// from the literal. So `wchar_t wa[] = L"ab"` emitted `61 00 62 00 00 00` and then
// declared the object `int[4]`. Measured before the fix, `sizeof(L"ab")` was 12 and
// after it is 6, with the bytes unchanged.
//
// `Lu` and `LU` are not in C11, but the tokenizer has always accepted them, and taking
// their width from the second letter costs one `match` arm.
pub fn wide_literal_type(tok &ast.Token) ?&ast.Type {
	text := tok.text
	if text.len < 2 {
		return none
	}
	match text[0] {
		`L` {
			match text[1] {
				`u` { return ty_ushort }
				`U` { return ty_uint }
				else { return ty_ushort }
			}
		}
		`u` {
			// `u8` is the one prefix that means *narrower*, and testing the second
			// character is the whole difference between one byte and two.
			if text[1] == `8` {
				return ty_char
			}
			return ty_ushort
		}
		`U` { return ty_uint }
		else { return none }
	}
}
