module fcc
import ast

// Statements, assignment and function calls.
//
// This is chibicc's `parse.c` statement half. It lives in its own file rather than at
// the end of `parser.v` because `parser.v` is already the longest file in the project
// and the split is along a real seam: everything here needs a function body to be
// meaningful, and everything in `parser.v` does not.

// --- statements ---

// stmt parses one statement.
//
//	stmt = "return" expr? ";"
//	     | "if" "(" expr ")" stmt ("else" stmt)?
//	     | "switch" "(" expr ")" stmt
//	     | "case" const-expr ("..." const-expr)? ":" stmt
//	     | "default" ":" stmt
//	     | "for" "(" expr-stmt expr? ";" expr? ")" stmt
//	     | "while" "(" expr ")" stmt
//	     | "do" stmt "while" "(" expr ")" ";"
//	     | "goto" (ident | "*" expr) ";"
//	     | "break" ";"
//	     | "continue" ";"
//	     | ident ":" stmt
//	     | "{" compound-stmt
//	     | expr-stmt
fn (mut p Parser) stmt() &ast.Node {
	tok := p.tok()

	if p.at('return') {
		p.pos++
		mut node := p.new_node(.return_, tok)
		if p.consume(';') {
			return node
		}
		mut exp := p.expr()
		add_type(mut exp)
		// A value returned from a function whose result is a struct is the struct
		// itself; anything else is converted to the declared return type, which is
		// also how `return f();` in a void function discards the result.
		if rty := p.return_type() {
			if rty.kind != .struct_ && rty.kind != .union_ {
				exp = new_cast(exp, rty)
			}
		}
		node.lhs = exp
		p.expect(';')
		return node
	}

	if p.at('__asm__') || p.at('asm') || p.at('__asm') {
		return p.asm_stmt()
	}

	if p.at('if') {		p.pos++
		mut node := p.new_node(.if_, tok)
		p.expect('(')
		mut cond := p.expr()
		add_type(mut cond)
		node.cond = cond
		p.expect(')')
		node.then = p.stmt()
		if p.consume('else') {
			node.els = p.stmt()
		}
		return node
	}

	if p.at('switch') {
		p.pos++
		mut node := p.new_node(.switch_, tok)
		p.expect('(')
		mut cond := p.expr()
		add_type(mut cond)
		node.cond = cond
		p.expect(')')

		outer_switch := p.current_switch
		outer_brk := p.brk_label
		p.current_switch = node
		p.brk_label = p.new_unique_name()
		node.brk_label = p.brk_label

		node.then = p.stmt()

		p.current_switch = outer_switch
		p.brk_label = outer_brk
		return node
	}

	if p.at('case') {
		if p.current_switch == unsafe { nil } {
			p.error_here('stray case')
		}
		p.pos++
		mut node := p.new_node(.case_, tok)
		begin := p.const_expr()
		mut end := begin
		if p.consume('...') {
			// [GNU] A case range, as in `case 1 ... 5:`.
			end = p.const_expr()
			if end < begin {
				p.error_here('empty case range')
			}
		}
		p.expect(':')
		node.unique_label = p.new_unique_name()
		node.begin = begin
		node.end = end
		node.lhs = p.stmt()
		mut sw := p.current_switch
		if sw != unsafe { nil } {
			node.label_name = sw.unique_label
			sw.cases << node
		}
		return node
	}

	if p.at('default') {
		if p.current_switch == unsafe { nil } {
			p.error_here('stray default')
		}
		p.pos++
		mut node := p.new_node(.case_, tok)
		p.expect(':')
		node.unique_label = p.new_unique_name()
		node.lhs = p.stmt()
		mut sw := p.current_switch
		if sw != unsafe { nil } {
			sw.default_case = node
		}
		return node
	}

	if p.at('for') {
		p.pos++
		mut node := p.new_node(.for_, tok)
		p.expect('(')

		p.enter_scope()
		outer_brk := p.brk_label
		outer_cont := p.cont_label
		p.brk_label = p.new_unique_name()
		p.cont_label = p.new_unique_name()
		node.brk_label = p.brk_label
		node.cont_label = p.cont_label

		// The first clause is a declaration or an expression, and `is_typename` is what
		// tells them apart: `for (int i = 0; ...)` declares, `for (i = 0; ...)` assigns.
		if p.is_typename() && p.tok_at(1).text != ':' {
			mut attr := VarAttr{}
			basety := p.declspec(&attr)
			if attr.is_typedef {
				p.parse_typedef(basety)
				// A typedef cannot be the whole clause, so the loop is malformed. The
				// tokens up to the `;` are dropped rather than parsed as an expression.
				p.skip_to_paren_close()
			} else {
				node.init = p.declaration(basety, attr)
			}
		} else {
			node.init = p.expr_stmt()
		}

		if !p.at(';') {
			mut cond := p.expr()
			add_type(mut cond)
			node.cond = cond
		}
		p.expect(';')

		if !p.at(')') {
			mut inc := p.expr()
			add_type(mut inc)
			node.inc = inc
		}
		p.expect(')')

		node.then = p.stmt()

		p.leave_scope()
		p.brk_label = outer_brk
		p.cont_label = outer_cont
		return node
	}

	if p.at('while') {
		p.pos++
		// A `while` is a `for` with no init and no inc. Representing it as one means the
		// backend has a single loop shape rather than two that differ only in what is
		// missing.
		mut node := p.new_node(.for_, tok)
		p.expect('(')
		mut cond := p.expr()
		add_type(mut cond)
		node.cond = cond
		p.expect(')')

		outer_brk := p.brk_label
		outer_cont := p.cont_label
		p.brk_label = p.new_unique_name()
		p.cont_label = p.new_unique_name()
		node.brk_label = p.brk_label
		node.cont_label = p.cont_label

		node.then = p.stmt()

		p.brk_label = outer_brk
		p.cont_label = outer_cont
		return node
	}

	if p.at('do') {
		p.pos++
		mut node := p.new_node(.do_, tok)

		outer_brk := p.brk_label
		outer_cont := p.cont_label
		p.brk_label = p.new_unique_name()
		p.cont_label = p.new_unique_name()
		node.brk_label = p.brk_label
		node.cont_label = p.cont_label

		node.then = p.stmt()

		p.brk_label = outer_brk
		p.cont_label = outer_cont

		p.expect('while')
		p.expect('(')
		mut cond := p.expr()
		add_type(mut cond)
		node.cond = cond
		p.expect(')')
		p.expect(';')
		return node
	}

	if p.at('asm') {
		// [GNU] An asm statement's meaning is in the string it carries, and there is no
		// way to honour it from a tree. Reporting beats emitting a call to nothing.
		p.error_here('asm statements are not supported')
		p.pos++
		p.skip_to_decl_end()
		return p.new_node(.null_stmt, tok)
	}

	if p.at('goto') {
		p.pos++
		if p.at('*') {
			// [GNU] `goto *expr` jumps to an address computed at run time.
			p.pos++
			mut node := p.new_node(.goto_expr, tok)
			mut target := p.expr()
			add_type(mut target)
			node.lhs = target
			p.expect(';')
			return node
		}
		mut node := p.new_node(.goto_, tok)
		node.label_name = p.tok().text
		p.pos++
		p.gotos << node
		p.expect(';')
		return node
	}

	if p.at('break') {
		if p.brk_label == '' {
			p.error_here('stray break')
		}
		mut node := p.new_node(.goto_, tok)
		node.unique_label = p.brk_label
		p.pos++
		p.expect(';')
		return node
	}

	if p.at('continue') {
		if p.cont_label == '' {
			p.error_here('stray continue')
		}
		mut node := p.new_node(.goto_, tok)
		node.unique_label = p.cont_label
		p.pos++
		p.expect(';')
		return node
	}

	if p.tok().kind == .ident && p.tok_at(1).text == ':' {
		mut node := p.new_node(.label, tok)
		node.label_name = tok.text
		node.unique_label = p.new_unique_name()
		p.pos += 2
		node.lhs = p.stmt()
		p.labels << node
		return node
	}

	if p.at('{') {
		p.pos++
		return p.compound_stmt()
	}

	return p.expr_stmt()
}

// return_type is the declared result type of the function being parsed, or none.
fn (p &Parser) return_type() ?&ast.Type {
	if p.current_fn == unsafe { nil } || p.current_fn.ty == unsafe { nil } {
		return none
	}
	return p.current_fn.ty.ret_type
}

// skip_to_paren_close drops tokens up to the `)` that closes an enclosing clause.
//
// It exists for the one malformed `for` clause a typedef can produce, where the
// grammar has nothing left to parse and stopping would leave the cursor inside the
// parentheses for every later statement to trip over.
fn (mut p Parser) skip_to_paren_close() {
	mut depth := 0
	for p.tok().kind != .eof {
		if p.at(')') {
			if depth == 0 {
				return
			}
			depth--
		} else if p.at('(') {
			depth++
		}
		p.pos++
	}
}

// compound_stmt parses a block: a sequence of declarations and statements in their
// own scope.
fn (mut p Parser) compound_stmt() &ast.Node {
	tok := p.tok()
	mut node := p.new_node(.block_, tok)
	mut stmts := []&ast.Node{}

	p.enter_scope()
	for !p.at('}') {
		if p.tok().kind == .eof {
			p.error_here('unterminated block: "}" expected')
			break
		}
		// `is_typename` and the token after it decide which this is: `x: ...` is a
		// label even when x happens to be a typedef name, and a nested function
		// definition is legal in GNU C.
		if p.is_typename() && p.tok_at(1).text != ':' {
			mut attr := VarAttr{}
			basety := p.declspec(&attr)
			if attr.is_typedef {
				p.parse_typedef(basety)
				continue
			}
			if p.is_function() {
				p.function(basety, attr)
				continue
			}
			if attr.is_extern {
				p.global_variable(basety, attr)
				continue
			}
			stmts << p.declaration(basety, attr)
			continue
		}
		stmts << p.stmt()
	}
	p.leave_scope()

	p.expect('}')
	node.body = stmts
	return node
}

// asm_stmt parses a GNU `__asm__` statement.
//
//	asm-stmt = ("asm" | "__asm__") ["volatile" | "__volatile__"] "(" temps [":" outs [":" ins [":" clobbers]]] ")"
//
// Each of `outs`, `ins` and `clobbers` is a comma-separated list, and the first two hold
// a constraint string in parentheses followed by an expression in parentheses. Operands
// are collected as one list — outputs then inputs, which is the order `%N` numbers them
// in — with the constraint's modifier stripped so the backend can tell a write from a
// read without re-parsing it.
//
// Only the memory constraint is modelled. `tcc/tcc_libm.h` uses `"=m"` and `"m"` and
// nothing else, which is what `math.h` and `tgmath.h` are blocked on; a register
// constraint is reported as unsupported rather than guessed at, because a wrong
// constraint is a silently wrong program rather than a visible failure.
fn (mut p Parser) asm_stmt() &ast.Node {
	tok := p.tok()
	p.pos++
	// `volatile` is a promise the optimiser has not been written to keep, so it is read
	// and discarded: an `__asm__` in this generator is never removed and never
	// reordered relative to the statements around it either way.
	for p.at('volatile') || p.at('__volatile__') {
		p.pos++
	}
	p.expect('(')

	// The template. Adjacent string literals are one template, as everywhere else in
	// C — `"fldl %1\n" "fistpl %0"` is one string, so it has to be read as one run.
	t := p.tok()
	if t.kind != .str_ {
		p.error_at(t, 'expected a string literal in __asm__')
		p.skip_to_decl_end()
		return p.new_node(.null_stmt, tok)
	}
	mut tmpl := ''
	for piece in p.string_run() {
		tmpl += piece.str_data.bytestr()
	}

	mut ops := []&ast.Node{}
	mut constraints := []string{}

	// Group 0 is the outputs, group 1 the inputs, group 2 the clobbers.
	for p.at(':') {
		p.pos++
		for !p.at(':') && !p.at(')') {
			if p.consume(',') {
				continue
			}
			c := p.tok()
			if c.kind != .str_ {
				p.error_at(c, 'expected a constraint string in __asm__')
				p.skip_to_decl_end()
				return p.new_node(.null_stmt, tok)
			}
			cs := c.str_data.bytestr()
			p.pos++
			// A clobber names a register, not an expression, so it has no operand.
			if cs == 'memory' || cs == 'cc' {
				continue
			}
			p.expect('(')
			mut exp := p.assign()
			add_type(mut exp)
			p.expect(')')
			// The modifier is stripped so the backend sees `m` for both `"=m"` and
			// `"+m"` and can decide what it means from whether the operand is an output.
			//
			// Stripped by a loop rather than `trim_string_left`, because a multi-character
			// cutset does not trim anything in this V build: measured, `"=m"` with a
			// `"=+&%"` cutset comes back unchanged, while one character at a time works.
			mut bare := cs
			for bare.len > 0 {
				m0 := bare[0]
				if m0 == `=` || m0 == `+` || m0 == `&` || m0 == `%` {
					bare = bare[1..]
				} else {
					break
				}
			}
			if bare != 'm' {
				p.error_at(c, 'asm constraint "${cs}" is not supported; only "m" is')
			}
			constraints << bare
			ops << exp
		}
	}
	p.expect(')')
	p.expect(';')

	mut node := p.new_node(.asm, tok)
	node.asm_template = tmpl
	node.asm_ops = ops
	node.asm_constraints = constraints
	return node
}

// expr_stmt parses `expr? ";"`. A bare `;` is an empty block rather than an empty
// expression statement, so the backend has no null expression to test for.
fn (mut p Parser) expr_stmt() &ast.Node {
	tok := p.tok()
	if p.consume(';') {
		return p.new_node(.block_, tok)
	}
	mut expr := p.expr()
	add_type(mut expr)
	node := p.expr_stmt_of(expr)
	p.expect(';')
	return node
}

// resolve_goto_labels matches every `goto` with the label it names.
//
// A forward goto is the normal case — `goto done;` usually appears before `done:` — so
// the two are collected during the parse and matched here, once the body has been read.
fn (mut p Parser) resolve_goto_labels() {
	for mut g in p.gotos {
		mut found := false
		for label in p.labels {
			if label.label_name == g.label_name {
				g.unique_label = label.unique_label
				found = true
				break
			}
		}
		if !found {
			p.error_at(g.tok, 'use of undeclared label "${g.label_name}"')
		}
	}
	p.gotos = []
	p.labels = []
}

// --- assignment ---

// expr parses a comma-separated expression list, which is a single expression whose
// value is the last one.
fn (mut p Parser) expr() &ast.Node {
	mut node := p.assign()
	if p.at(',') {
		tok := p.next()
		rhs := p.expr()
		mut comma := p.new_binary(.comma, node, rhs, tok)
		add_type(mut comma)
		return comma
	}
	return node
}

// assign parses an assignment or, failing that, a conditional expression.
//
//	assign    = conditional (assign-op assign)?
//	assign-op = "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^="
//	          | "<<=" | ">>="
//
// The right-hand side is parsed by `assign` rather than by `conditional`, so `a = b = c`
// assigns right to left as C requires.
fn (mut p Parser) assign() &ast.Node {
	mut lhs := p.conditional()

	if p.at('=') {
		tok := p.next()
		mut rhs := p.assign()
		mut node := p.new_binary(.assign, lhs, rhs, tok)
		add_type(mut node)
		return node
	}

	// The compound forms are lowered to `tmp = &A, *tmp = *tmp op B` rather than read as
	// a single node, because the address of the target is taken once: `a[i()] += 1` may
	// not call `i()` twice.
	kind, is_add, is_sub := compound_assign_op(p.tok().text)
	if kind == ast.NodeKind.assign {
		return lhs
	}
	tok := p.next()
	mut rhs := p.assign()

	if is_add {
		return p.to_assign(p.new_add(mut lhs, mut rhs, tok))
	}
	if is_sub {
		return p.to_assign(p.new_sub(mut lhs, mut rhs, tok))
	}
	mut binary := p.new_binary(kind, lhs, rhs, tok)
	return p.to_assign(binary)
}

// compound_assign_op maps an assignment operator's spelling to the node kind it is
// built from, and says which two forms need pointer arithmetic.
//
// `kind == .assign` means the token was not a compound assignment at all, which is how
// the caller recognises the plain case without a second lookup.
fn compound_assign_op(text string) (ast.NodeKind, bool, bool) {
	return match text {
		'+=' { ast.NodeKind.add, true, false }
		'-=' { ast.NodeKind.sub, false, true }
		'*=' { ast.NodeKind.mul, false, false }
		'/=' { ast.NodeKind.div, false, false }
		'%=' { ast.NodeKind.mod, false, false }
		'&=' { ast.NodeKind.bit_and, false, false }
		'|=' { ast.NodeKind.bit_or, false, false }
		'^=' { ast.NodeKind.bit_xor, false, false }
		'<<=' { ast.NodeKind.shl, false, false }
		'>>=' { ast.NodeKind.shr, false, false }
		else { ast.NodeKind.assign, false, false }
	}
}

// to_assign rewrites `A op= B` so that A is evaluated once.
//
// A struct member is the case that needs it: `s.f += 1` becomes
// `tmp = &s, (*tmp).f = (*tmp).f + 1`, because `&s.f` is not an lvalue C can assign
// through and because reading `s` twice would be wrong if it were.
fn (mut p Parser) to_assign(binary &ast.Node) &ast.Node {
	mut lhs := binary.lhs
	mut rhs := binary.rhs
	add_type(mut lhs)
	add_type(mut rhs)
	tok := binary.tok

	if lhs.ty.is_atomic {
		// chibicc expands this into a compare-and-swap loop in a statement
		// expression. The node kind that needs does not exist yet, and emitting the
		// non-atomic form instead would silently drop the atomicity, so it is reported.
		p.error_at(tok, 'compound assignment to an atomic object is not supported yet')
	}

	// The conversion the binary operator's own typing inserted has to be looked through
	// before asking whether the target is a member: `usual_arith_conv` wraps *both*
	// operands in a cast unconditionally, so `s.a += 1` arrives here as
	// `cast(s.a) + 1` and a test on `lhs.kind == .member` never fires. That sends a
	// member compound assignment down the plain path, which takes `&s.a` — not an
	// lvalue C can assign through, and an outright error for a bitfield.
	mut target := lhs
	for target.kind == .cast {
		target = target.lhs
	}

	if target.kind == .member {
		tmp := p.new_lvar('', pointer_to(target.ty), tok.line.disp_line)

		mut take := p.new_binary(.assign, p.new_var_node(tmp, tok), p.new_unary(.addr,
			target.lhs, tok), tok)
		add_type(mut take)

		mut load := p.new_unary(.member, p.new_unary(.deref, p.new_var_node(tmp, tok),
			tok), tok)
		load.member = target.member
		add_type(mut load)

		mut stored := p.new_unary(.member, p.new_unary(.deref, p.new_var_node(tmp, tok),
			tok), tok)
		stored.member = target.member
		add_type(mut stored)

		mut combined := p.new_binary(binary.kind, stored, rhs, tok)
		add_type(mut combined)
		mut put := p.new_binary(.assign, load, combined, tok)
		add_type(mut put)

		mut comma := p.new_binary(.comma, take, put, tok)
		add_type(mut comma)
		return comma
	}

	// `target` has had the conversion stripped off it, so it is what the address is
	// taken of. Using `lhs` here instead is what produces a backend error for every
	// `x += 1`: the conversion wraps the target in a `.cast`, and an address of a cast
	// is not an lvalue.
	tmp := p.new_lvar('', pointer_to(target.ty), tok.line.disp_line)
	mut take := p.new_binary(.assign, p.new_var_node(tmp, tok), p.new_unary(.addr,
		target, tok), tok)
	add_type(mut take)

	mut load := p.new_unary(.deref, p.new_var_node(tmp, tok), tok)
	add_type(mut load)
	mut combined := p.new_binary(binary.kind, load, rhs, tok)
	add_type(mut combined)
	mut put := p.new_binary(.assign, p.new_unary(.deref, p.new_var_node(tmp, tok), tok),
		combined, tok)
	add_type(mut put)

	mut comma := p.new_binary(.comma, take, put, tok)
	add_type(mut comma)
	return comma
}

// new_inc_dec rewrites a postfix `++` or `--` as `(typeof A)((A += 1) - 1)`.
//
// The value of `A++` is A's old value, and there is no node for "the old value" that
// survives an assignment, so the old value is recovered arithmetically.
fn (mut p Parser) new_inc_dec(node &ast.Node, tok ast.Token, addend i64) &ast.Node {
	mut operand := node
	add_type(mut operand)
	mut one := p.new_num(addend, tok)
	add_type(mut one)
	mut bumped := p.new_add(mut operand, mut one, tok)
	mut assigned := p.to_assign(bumped)
	mut minus := p.new_num(-addend, tok)
	add_type(mut minus)
	mut back := p.new_add(mut assigned, mut minus, tok)
	return new_cast(back, operand.ty)
}

// --- calls ---

// funcall parses the argument list of a call and builds the call.
//
//	funcall = (assign ("," assign)*)? ")"
//
// A struct or union result is given a buffer local here rather than by the caller of
// the callee, because on x86-64 it is returned in memory that has to belong to someone.
fn (mut p Parser) funcall(callee &ast.Node) &ast.Node {
	tok := p.tok()
	mut target := callee
	add_type(mut target)

	if target.ty.kind != .func && !(target.ty.kind == .pointer
		&& target.ty.base.kind == .func) {
		p.error_at(target.tok, 'called object is not a function')
	}
	// `(*fp)(1)` and `fp(1)` are the same call, and chibicc keeps the function type
	// either way so the backend has one case rather than two.
	ty := if target.ty.kind == .func { target.ty } else { target.ty.base }
	// The parameter list is walked by index rather than resliced, because reslicing a
	// field of an immutable type has to clone it and this runs once per call.
	mut param_i := 0

	mut args := []&ast.Node{}
	for !p.at(')') {
		if p.tok().kind == .eof {
			p.error_here('unterminated argument list')
			break
		}
		if args.len > 0 {
			p.expect(',')
			if p.at(')') {
				break
			}
		}
		mut arg := p.assign()
		add_type(mut arg)

		mut has_param := param_i < ty.params.len
		if has_param {
			param_i++
		} else if !ty.is_variadic {
			p.error_here('too many arguments')
		}

		if has_param {
			next := ty.params[param_i - 1]
			// A struct or union is passed by value, so it is not cast: a cast would
			// copy it and the callee would write into the copy.
			if next.kind != .struct_ && next.kind != .union_ {
				arg = new_cast(arg, next)
			}
		} else if arg.ty.kind == .basic && arg.ty.basic == .float_ {
			// [C99 6.5.2.2p6] A float passed through `...` is promoted to double,
			// because there is no varargs type to carry a float.
			arg = new_cast(arg, ty_double)
		}
		args << arg
	}
	if param_i < ty.params.len {
		p.error_here('too few arguments')
	}
	p.expect(')')

	mut node := p.new_unary(.funcall, target, tok)
	node.func_ty = ty
	node.ty = ty.ret_type
	node.args = args
	if node.ty != unsafe { nil } && (node.ty.kind == .struct_ || node.ty.kind == .union_) {
		node.ret_buffer = p.new_lvar('', node.ty, tok.line.disp_line)
	}
	return node
}

// generic_selection parses `_Generic`, which picks an association by the controlling
// expression's type.
//
//	generic-selection = "(" assign "," generic-assoc ("," generic-assoc)* ")"
//	generic-assoc     = type-name ":" assign | "default" ":" assign
//
// An array or function controlling expression is matched as a pointer to its element
// or to itself, which is what [C11 6.5.1.1p3] requires: a generic selection never
// matches an array type, because an array decays before it is ever a type.
fn (mut p Parser) generic_selection() &ast.Node {
	tok := p.tok()
	p.expect('(')
	mut ctrl := p.assign()
	add_type(mut ctrl)

	mut ctrl_ty := ctrl.ty
	if ctrl_ty.kind == .func {
		ctrl_ty = pointer_to(ctrl_ty)
	} else if ctrl_ty.kind == .array {
		ctrl_ty = pointer_to(ctrl_ty.base)
	} else if ctrl_ty.kind == .vla {
		ctrl_ty = pointer_to(ctrl_ty.base)
	}

	mut ret := unsafe { nil }
	mut default_ret := unsafe { nil }
	for !p.consume(')') {
		if p.tok().kind == .eof {
			break
		}
		p.expect(',')
		if p.at('default') {
			p.pos++
			p.expect(':')
			node := p.assign()
			if default_ret == unsafe { nil } {
				default_ret = node
			}
			continue
		}
		assoc_ty := p.typename()
		p.expect(':')
		node := p.assign()
		// The last matching association wins, as [C11 6.5.1.1p2] requires.
		if is_exact_type_match(ctrl_ty, assoc_ty) {
			ret = node
		}
	}
	if ret == unsafe { nil } {
		ret = default_ret
	}
	if ret == unsafe { nil } {
		p.error_at(tok, 'no generic association matches the controlling expression')
		return p.new_num(0, tok)
	}
	return ret
}
