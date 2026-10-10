module fcc
import ast

// Constant expressions, and the writing of initializer byte images.
//
// This is separated from parser.v because it is a different kind of thing: the
// parser decides what the source says, and everything here decides what that means
// at a fixed address. Splitting them also means the rules that decide a constant
// expression's value can be tested without a token stream.
//
// The two questions the evaluator answers are separate on purpose. `eval` gives the
// number; `eval2` additionally reports whether the expression named a symbol and
// what offset from it, because a symbol in a constant expression is only legal as
// the initializer of a global — it becomes a relocation, and a relocation needs an
// address that no compiler can know yet.

// is_address_form reports whether an expression denotes a symbol's address rather than
// a value read out of one.
//
// The distinction is what makes `int *p = &table[3];` and `char *s = "abc";` legal and
// `int z = y + 1;` and `int *q = p;` not, and `eval2` cannot tell the two groups apart
// on its own: a variable's name is what an address is built from. What separates them is
// that a legal one mentions an address — a `&`, or a name of an array or of a function,
// which decays to its own address.
//
// Measured against tcc, which reports `initializer element is not constant` for both
// `int z = y + 1;` and `int *q = p;` and accepts the two legal forms.
fn is_address_form(mut n &ast.Node) bool {
	// A call, an assignment and a statement expression have no address at all, and one
	// anywhere in the initializer disqualifies the whole of it.
	if n.kind == .funcall || n.kind == .assign || n.kind == .stmt_expr {
		return false
	}
	if n.kind == .addr {
		return true
	}
	// [GNU] `&&label` is a label's address, and nothing else. It is the address form
	// that makes `static void *p[] = {&&done}` a legal constant expression: the label
	// is in the function whose initializer this is, so the address is fixed once the
	// function has been parsed.
	if n.kind == .goto_expr {
		return true
	}
	// An array or function name is its own address: `table` and `&table[0]` agree, and
	// a string literal is an array.
	if n.kind == .var_ref && (n.var.ty.kind == .array || n.var.ty.kind == .func) {
		return true
	}
	for raw in [n.lhs, n.rhs, n.cond, n.then, n.els] {
		if raw == unsafe { nil } {
			continue
		}
		mut child := raw
		if is_address_form(mut child) {
			return true
		}
	}
	return false
}
// ConstValue is what evaluating a constant expression produced.
//
// The label and the flag are kept apart from the value because a symbol is only legal
// in a constant expression as the initializer of a global, where it becomes a
// relocation. Returning all three lets the caller decide, which two return values
// could not: `label` alone cannot say whether it is set, since a symbol may legitimately
// have an empty name.
struct ConstValue {
mut:
	value i64
	label string
	has_label bool
}

// eval returns the value of a constant expression.
//
// An expression that names a symbol evaluates to its offset from that symbol with the
// symbol discarded, which is what makes `&g + 8` contribute 8. A caller that cares
// about the symbol uses eval2.
fn eval(mut node &ast.Node) i64 {
	return eval2(mut node).value
}

// eval2 evaluates a constant expression and reports whether it named a symbol.
fn eval2(mut node &ast.Node) ConstValue {
	if node == unsafe { nil } {
		return ConstValue{}
	}
	add_type(mut node)
	if node.ty != unsafe { nil } && is_flonum(node.ty) {
		return ConstValue{
			value: i64(eval_double(mut node))
		}
	}
	match node.kind {
		// The left operand carries the symbol and the right one only ever contributes a
		// number, so `sym + 8` and `8 + sym` both keep the symbol and add the offsets.
		// Building a fresh ConstValue from the value alone — which is what this did first —
		// silently turns every address constant back into a plain integer.
		.add {
			return offset(eval2(mut node.lhs), eval(mut node.rhs))
		}
		.sub {
			return offset(eval2(mut node.lhs), -eval(mut node.rhs))
		}
		.mul { return ConstValue{value: eval(mut node.lhs) * eval(mut node.rhs)} }
		.div {
			if node.ty.is_unsigned {
				return ConstValue{
					value: i64(u64(eval(mut node.lhs)) / u64(eval(mut node.rhs)))
				}
			}
			return ConstValue{
				value: eval(mut node.lhs) / eval(mut node.rhs)
			}
		}
		.neg { return ConstValue{value: -eval(mut node.lhs)} }
		.mod {
			if node.ty.is_unsigned {
				return ConstValue{
					value: i64(u64(eval(mut node.lhs)) % u64(eval(mut node.rhs)))
				}
			}
			return ConstValue{
				value: eval(mut node.lhs) % eval(mut node.rhs)
			}
		}
		.bit_and { return ConstValue{value: eval(mut node.lhs) & eval(mut node.rhs)} }
		.bit_or { return ConstValue{value: eval(mut node.lhs) | eval(mut node.rhs)} }
		.bit_xor { return ConstValue{value: eval(mut node.lhs) ^ eval(mut node.rhs)} }
		.shl { return ConstValue{value: eval(mut node.lhs) << eval(mut node.rhs)} }
		.shr {
			// Only a 64-bit unsigned shift goes through the unsigned path: a signed right
			// shift has to keep its sign, which is why the width is part of the test
			// rather than just the signedness.
			if node.ty.is_unsigned && node.ty.size == 8 {
				return ConstValue{
					value: i64(u64(eval(mut node.lhs)) >> eval(mut node.rhs))
				}
			}
			return ConstValue{
				value: eval(mut node.lhs) >> eval(mut node.rhs)
			}
		}
		.eq { return ConstValue{value: b2i(eval(mut node.lhs) == eval(mut node.rhs))} }
		.ne { return ConstValue{value: b2i(eval(mut node.lhs) != eval(mut node.rhs))} }
		.lt {
			if node.lhs.ty.is_unsigned {
				return ConstValue{
					value: b2i(u64(eval(mut node.lhs)) < u64(eval(mut node.rhs)))
				}
			}
			return ConstValue{
				value: b2i(eval(mut node.lhs) < eval(mut node.rhs))
			}
		}
		.le {
			if node.lhs.ty.is_unsigned {
				return ConstValue{
					value: b2i(u64(eval(mut node.lhs)) <= u64(eval(mut node.rhs)))
				}
			}
			return ConstValue{
				value: b2i(eval(mut node.lhs) <= eval(mut node.rhs))
			}
		}
		.cond_expr {
			if eval(mut node.cond) != 0 {
				return eval2(mut node.then)
			}
			return eval2(mut node.els)
		}
		.comma { return eval2(mut node.rhs) }
		.not { return ConstValue{value: b2i(eval(mut node.lhs) == 0)} }
		.bit_not { return ConstValue{value: ~eval(mut node.lhs)} }
		.log_and {
			return ConstValue{
				value: b2i(eval(mut node.lhs) != 0 && eval(mut node.rhs) != 0)
			}
		}
		.log_or {
			return ConstValue{
				value: b2i(eval(mut node.lhs) != 0 || eval(mut node.rhs) != 0)
			}
		}
		.cast {
			mut inner := eval2(mut node.lhs)
			if is_integer(node.ty) {
				inner.value = truncate(inner.value, node.ty)
			}
			return inner
		}
		.addr { return eval_rval(mut node.lhs) }
		.member {
			m := node.member or { return ConstValue{} }
			// The address of a field is only meaningful for an array, where the element's
			// address is the field's address. For anything else there is no constant
			// value, and returning the offset alone would be a plausible wrong answer
			// rather than an obvious one.
			if m.ty.kind != .array {
				return ConstValue{}
			}
			mut out := eval_rval(mut node.lhs)
			out.value += i64(m.offset)
			return out
		}
		.var_ref {
			if node.var.ty.kind != .array && node.var.ty.kind != .func {
				return ConstValue{}
			}
			return ConstValue{
				label:     node.var.name
				has_label: true
			}
		}
		.num { return ConstValue{value: node.num} }
		// [GNU] A label as a value. `unique_label` is the spelling the backend emits for
		// the label, so the relocation names exactly what the definition will be called.
		//
		// It is empty until `resolve_goto_labels` has matched the label, which is why a
		// static local holding one has its byte image written after the body is parsed —
		// see `gvar_initializer_in_function`. `has_label` is tied to that rather than to
		// the node's kind, so an unresolved one is still reported as "not a constant"
		// instead of becoming a relocation to an empty symbol name, which no assembler
		// can diagnose usefully.
		.goto_expr {
			return ConstValue{
				label:     node.unique_label
				has_label: node.unique_label != ''
			}
		}
		// A `.generic` node stands for something the parser could not read and was
		// already reported where it was parsed. Answering zero here keeps one
		// unsupported construct from producing a diagnostic at every enclosing level.
		else { return ConstValue{} }
	}
}

// eval_rval evaluates the operand of an address-of expression.
fn eval_rval(mut node &ast.Node) ConstValue {
	if node == unsafe { nil } {
		return ConstValue{}
	}
	match node.kind {
		.var_ref {
			// The address of a local is not a constant at all: it depends on where the
			// frame lands.
			if node.var.is_local {
				return ConstValue{}
			}
			return ConstValue{
				label:     node.var.name
				has_label: true
			}
		}
		.deref { return eval2(mut node.lhs) }
		.member {
			m := node.member or { return ConstValue{} }
			mut out := eval_rval(mut node.lhs)
			out.value += i64(m.offset)
			return out
		}
		else { return ConstValue{} }
	}
}

// truncate reduces val to the width and signedness of ty, which is what a cast does.
fn truncate(val i64, ty &ast.Type) i64 {
	match ty.size {
		1 {
			return if ty.is_unsigned {
				i64(u8(val))
			} else {
				i64(i8(val))
			}
		}
		2 {
			return if ty.is_unsigned {
				i64(u16(val))
			} else {
				i64(i16(val))
			}
		}
		4 {
			return if ty.is_unsigned {
				i64(u32(val))
			} else {
				i64(i32(val))
			}
		}
		else { return val }
	}
}

fn b2i(b bool) i64 {
	return if b { 1 } else { 0 }
}

// offset adds a plain number to a constant that may name a symbol, keeping the symbol.
//
// This is the whole of `ptr + n` and `ptr - n` for a constant expression: the symbol
// stays and the number becomes the addend the relocation records.
fn offset(base ConstValue, by i64) ConstValue {
	return ConstValue{
		value:     base.value + by
		label:     base.label
		has_label: base.has_label
	}
}

// is_const_expr reports whether a node can be evaluated at compile time.
//
// It exists to tell a variable-length array from an ordinary one: `int a[n]` where n
// is a variable is a VLA, and `int a[3]` is not. Nothing else needs the answer.
fn is_const_expr(mut node &ast.Node) bool {
	if node == unsafe { nil } {
		return false
	}
	add_type(mut node)
	match node.kind {
		.add, .sub, .mul, .div, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .le, .log_and, .log_or {
			return is_const_expr(mut node.lhs) && is_const_expr(mut node.rhs)
		}
		.cond_expr {
			if !is_const_expr(mut node.cond) {
				return false
			}
			if eval(mut node.cond) != 0 {
				return is_const_expr(mut node.then)
			}
			return is_const_expr(mut node.els)
		}
		.comma { return is_const_expr(mut node.rhs) }
		.neg, .not, .bit_not, .cast { return is_const_expr(mut node.lhs) }
		.num { return true }
		// [GNU] A label's address is fixed before the program starts, so `&&done` is a
		// constant expression in exactly the sense `&g` is.
		.goto_expr { return true }
		else { return false }
	}
}

// eval_double evaluates a floating constant expression.
fn eval_double(mut node &ast.Node) f64 {
	if node == unsafe { nil } {
		return 0.0
	}
	add_type(mut node)
	if node.ty != unsafe { nil } && is_integer(node.ty) {
		if node.ty.is_unsigned {
			return f64(u64(eval(mut node)))
		}
		return f64(eval(mut node))
	}
	match node.kind {
		.add { return eval_double(mut node.lhs) + eval_double(mut node.rhs) }
		.sub { return eval_double(mut node.lhs) - eval_double(mut node.rhs) }
		.mul { return eval_double(mut node.lhs) * eval_double(mut node.rhs) }
		.div { return eval_double(mut node.lhs) / eval_double(mut node.rhs) }
		.neg { return -eval_double(mut node.lhs) }
		.cond_expr {
			if eval(mut node.cond) != 0 {
				return eval_double(mut node.then)
			}
			return eval_double(mut node.els)
		}
		.comma { return eval_double(mut node.rhs) }
		.cast {
			if node.lhs.ty != unsafe { nil } && is_flonum(node.lhs.ty) {
				return eval_double(mut node.lhs)
			}
			return f64(eval(mut node.lhs))
		}
		.num { return node.fval }
		else { return 0.0 }
	}
}

// --- writing initializer byte images ---

// gvar_initializer parses an initializer for a global and records its byte image.
//
// A global's initializer must be a constant expression, so it is evaluated here and
// written into `init_data`. Anything that needs an address becomes a relocation rather
// than a value, because no address is known yet.
fn (mut p Parser) gvar_initializer(mut obj &ast.Obj) {
	init, ty := p.parse_gvar_initializer(mut obj)
	p.write_gvar_bytes(mut obj, init, ty)
}

// gvar_initializer_in_function parses an initializer for a static local and leaves its
// byte image for `flush_static_inits`.
//
// [GNU] `static void *p[] = {&&done, &&loop}` is the reason this exists separately. A
// label used as a value names an address that can only be spelled once
// `resolve_goto_labels` has matched it to its definition, and that runs after the whole
// body has been read. The *parse* stays here, where the initializer is read and where
// an array's length is still being decided from it, and only the byte image waits.
//
// A file-scope global cannot need this: a label belongs to the function it appears in,
// so `&&x` in a file-scope initializer has no label to name.
fn (mut p Parser) gvar_initializer_in_function(mut obj &ast.Obj) {
	init, ty := p.parse_gvar_initializer(mut obj)
	p.deferred_static_inits << StaticInit{
		obj:  obj
		init: init
		ty:   ty
	}
}

// flush_static_inits writes the byte image of every static local declared in the
// function that has just been parsed. It runs after `resolve_goto_labels`, which is
// what makes a label used as a value spellable.
fn (mut p Parser) flush_static_inits() {
	for mut si in p.deferred_static_inits {
		p.write_gvar_bytes(mut si.obj, si.init, si.ty)
	}
	p.deferred_static_inits = []StaticInit{}
}

// parse_gvar_initializer reads an initializer and completes the object's type from it.
//
// The completion is not optional: `static int x[] = {1,2,3}` learns both its length and
// its size from the braces, and a later declaration that indexes `x` depends on it.
fn (mut p Parser) parse_gvar_initializer(mut obj &ast.Obj) (&Initializer, &ast.Type) {
	init, ty := p.initializer(obj.ty)
	obj.ty = ty
	return init, ty
}

// write_gvar_bytes evaluates a parsed initializer into the object's byte image.
fn (mut p Parser) write_gvar_bytes(mut obj &ast.Obj, init &Initializer, ty &ast.Type) {
	mut buf := []u8{len: ty.size, init: 0}
	mut rels := []ast.Relocation{}
	p.write_gvar_data(mut rels, init, ty, mut buf, 0)
	obj.init_data = buf
	obj.rel = rels
}

// lvar_initializer parses an initializer for a local and returns the statements that
// perform it.
//
// A local's initializer is not a constant, so it becomes assignments: `int x[2] = {6,7}`
// turns into `x[0]=6, x[1]=7`. The whole object is cleared first, which is how the
// elements the source did not mention come out zero.
fn (mut p Parser) lvar_initializer(mut obj &ast.Obj) &ast.Node {
	init, ty := p.initializer(obj.ty)
	obj.ty = ty
	desg := &InitDesg{
		obj: obj
		idx: 0
	}
	tok := p.tok()
	mut clear := p.new_node(.memzero, tok)
	clear.var = obj
	fill := p.create_lvar_init(init, ty, desg, tok)
	return p.new_binary(.comma, clear, fill, tok)
}

// create_lvar_init turns an initializer tree into the assignments that perform it.
fn (mut p Parser) create_lvar_init(init &Initializer, ty &ast.Type, desg &InitDesg,
	tok ast.Token) &ast.Node {
	if ty.kind == .array {
		mut node := p.new_node(.null_expr, tok)
		for i in 0 .. ty.array_len {
			if i >= init.children.len {
				break
			}
			step := &InitDesg{
				next: desg
				idx:  i
			}
			rhs := p.create_lvar_init(init.children[i], ty.base, step, tok)
			node = p.new_binary(.comma, node, rhs, tok)
		}
		return node
	}
	if ty.kind == .struct_ && init.expr == unsafe { nil } {
		mut node := p.new_node(.null_expr, tok)
		for i, mem in ty.members {
			if i >= init.children.len {
				break
			}
			step := &InitDesg{
				next:   desg
				idx:    0
				member: &ty.members[i]
			}
			rhs := p.create_lvar_init(init.children[i], mem.ty, step, tok)
			node = p.new_binary(.comma, node, rhs, tok)
		}
		return node
	}
	if ty.kind == .union_ {
		index := if init.mem_index >= 0 { init.mem_index } else { 0 }
		if index >= init.children.len {
			return p.new_node(.null_expr, tok)
		}
		step := &InitDesg{
			next:   desg
			idx:    0
			member: &ty.members[index]
		}
		return p.create_lvar_init(init.children[index], ty.members[index].ty, step, tok)
	}
	if init.expr == unsafe { nil } {
		return p.new_node(.null_expr, tok)
	}
	lhs := p.init_desg_expr(desg, tok)
	mut node := p.new_binary(.assign, lhs, init.expr, tok)
	add_type(mut node)
	return node
}

// init_desg_expr builds the lvalue a designator chain names: `x`, `x[2]`, `x[2].b`.
fn (mut p Parser) init_desg_expr(desg &InitDesg, tok ast.Token) &ast.Node {
	if desg.obj != unsafe { nil } {
		return p.new_var_node(desg.obj, tok)
	}
	if mem := desg.member {
		inner := p.init_desg_expr(desg.next, tok)
		mut node := p.new_unary(.member, inner, tok)
		node.member = *mem
		return node
	}
	mut base := p.init_desg_expr(desg.next, tok)
	mut index := p.new_num(i64(desg.idx), tok)
	// `x[i]` is `*(x + i)`.
	return p.new_unary(.deref, p.new_add(mut base, mut index, tok), tok)
}

// compute_vla_size returns the expression that works out a variable-length array's
// size at run time.
//
// The size is kept in a local the type records, because `sizeof` has to be able to
// read it later, and `sizeof` of a VLA is a run-time value.
fn (mut p Parser) compute_vla_size(mut ty &ast.Type, tok ast.Token) &ast.Node {
	mut node := p.new_node(.null_expr, tok)
	if ty.base != unsafe { nil } {
		node = p.new_binary(.comma, node, p.compute_vla_size(mut ty.base, tok), tok)
	}
	if ty.kind != .vla {
		return node
	}
	mut base_sz := p.new_num(i64(ty.base.size), tok)
	if ty.base.kind == .vla && ty.base.vla_size != unsafe { nil } {
		base_sz = p.new_var_node(ty.base.vla_size, tok)
	}
	ty.vla_size = p.new_lvar('', ty_size_t, tok.line.disp_line)
	product := p.new_binary(.mul, ty.vla_len, base_sz, tok)
	mut assign := p.new_binary(.assign, p.new_var_node(ty.vla_size, tok), product, tok)
	add_type(mut assign)
	return p.new_binary(.comma, node, assign, tok)
}

// write_gvar_data serializes an initializer tree into a byte image.
// A bitfield is read-modify-written rather than stored, because it shares bytes with
// its neighbours. An element with no initializer is left as zero, which is where C's
// "unspecified elements are zero" rule is implemented — nothing has to check for it.
fn (mut p Parser) write_gvar_data(mut rels []ast.Relocation, init &Initializer,
	ty &ast.Type, mut buf []u8, offset int) {
	if ty.kind == .array {
		sz := ty.base.size
		for i in 0 .. ty.array_len {
			if i >= init.children.len {
				break
			}
			p.write_gvar_data(mut rels, init.children[i], ty.base, mut buf, offset + sz * i)
		}
		return
	}
	if ty.kind == .struct_ {
		for i, mem in ty.members {
			if i >= init.children.len {
				break
			}
			child := init.children[i]
			if mem.is_bitfield {
				// Skipped rather than stopped at: a zero-width bitfield takes no
				// initializer, and a named one the source omitted leaves its bits zero.
				// Either way the members after it are still written, which is what
				// chibicc's `break` here gets wrong.
				if child.expr == unsafe { nil } {
					continue
				}
				p.write_bitfield(mut child.expr, mem, mut buf, offset + mem.offset)
				continue
			}
			p.write_gvar_data(mut rels, child, mem.ty, mut buf, offset + mem.offset)
		}
		return
	}
	if ty.kind == .union_ {
		if init.mem_index < 0 || init.mem_index >= init.children.len {
			return
		}
		mem := ty.members[init.mem_index]
		p.write_gvar_data(mut rels, init.children[init.mem_index], mem.ty, mut buf, offset)
		return
	}
	if init.expr == unsafe { nil } {
		return
	}

	if ty.kind == .basic && ty.basic == .float_ {
		write_float(mut buf, offset, f32(eval_double(mut init.expr)))
		return
	}
	if ty.kind == .basic && ty.basic == .double_ {
		write_double(mut buf, offset, eval_double(mut init.expr))
		return
	}

	// A global's initializer is fixed at compile time, so it has to be either a number
	// or an address. `eval2` folds what it can and returns zero for the rest, which
	// would write a plausible and wrong byte image, so what it could not evaluate is
	// reported. tcc says `initializer element is not constant` for both a call and a
	// plain read of another variable, and accepts `&table[3]`.
	mut value := eval2(mut init.expr)
	if !is_const_expr(mut init.expr) && !(value.has_label && is_address_form(mut init.expr)) {
		p.error_at(init.expr.tok, 'initializer element is not constant')
	}
	if !value.has_label {
		write_int(mut buf, offset, u64(value.value), ty.size)
		return
	}
	// The value is an address. The bytes stay zero and the object writer patches them
	// once the symbols have addresses.
	write_int(mut buf, offset, 0, ty.size)
	rels << ast.Relocation{
		offset: offset
		label:  value.label
		addend: value.value
	}
}

// write_bitfield merges a value into the bits one bitfield occupies.
fn (mut p Parser) write_bitfield(mut expr &ast.Node, mem &ast.Member, mut buf []u8,
	offset int) {
	sz := mem.ty.size
	old := read_int(buf, offset, sz)
	value := u64(eval(mut expr))
	mut mask := u64(0xffff_ffff_ffff_ffff)
	if mem.bit_width < 64 {
		mask = (u64(1) << mem.bit_width) - 1
	}
	write_int(mut buf, offset, old | ((value & mask) << mem.bit_offset), sz)
}

// read_int reads sz bytes at offset as an unsigned value, little-endian.
fn read_int(buf []u8, offset int, sz int) u64 {
	if sz <= 0 || offset + sz > buf.len {
		return 0
	}
	mut v := u64(0)
	for i in 0 .. sz {
		v |= u64(buf[offset + i]) << u64(8 * i)
	}
	return v
}

// write_int writes sz bytes at offset, little-endian.
fn write_int(mut buf []u8, offset int, val u64, sz int) {
	if sz <= 0 || offset + sz > buf.len {
		return
	}
	for i in 0 .. sz {
		buf[offset + i] = u8(val >> u64(8 * i))
	}
}

// float_bits and double_bits reinterpret a float as its integer encoding, which is what
// writing one into a byte image means. It is a reinterpretation of the same eight bytes, so it
// is unsafe in V's sense and safe in every other.
fn float_bits(val f32) u32 {
	return unsafe { *(&u32(&val)) }
}

fn double_bits(val f64) u64 {
	return unsafe { *(&u64(&val)) }
}

fn write_float(mut buf []u8, offset int, val f32) {
	write_int(mut buf, offset, u64(float_bits(val)), 4)
}

fn write_double(mut buf []u8, offset int, val f64) {
	write_int(mut buf, offset, double_bits(val), 8)
}

// string_bytes returns a string literal's storage image, terminator included.
//
// The image is built rather than assembled from the token's bytes because the element
// width comes from the literal's prefix: a `L"abc"` is four bytes per element, not
// one.
fn string_bytes(tok &ast.Token, ty &ast.Type) []u8 {
	sz := ty.base.size
	mut buf := []u8{len: sz * ty.array_len, init: 0}
	for i in 0 .. ty.array_len {
		write_int(mut buf, i * sz, u64(string_unit(tok, i, sz)), sz)
	}
	return buf
}