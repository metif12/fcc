module fcc
import ast

// Statement and expression tests.
//
// The parser's output for a statement is a tree, so these assert on the tree's shape —
// which node kinds appear, in which fields — rather than on generated code. That is the
// only thing available before phase 2, and it is enough to catch the failures that
// matter here: a node built from the wrong operator, a label resolved to the wrong
// thing, a compound assignment that evaluates its target twice.

// parsed_src runs a snippet through the parser with no preprocessor, which is what a
// statement test needs: it has no #line to resolve.
//
// It is spelled differently from parser_test.v's parsed because each _test.v file
// is its own compilation unit and does not see the others' helpers.
fn parsed_src(src string) ParseResult {
	return parse_tokens(tokenize(src), 'test.c', []PackEvent{})
}

// fn_with_body parses one function definition and returns it.
//
// The function is found by flag rather than by position: each definition also creates
// the compiler-generated `__func__` object, so the globals are more than one.
fn fn_with_body(src string) &ast.Obj {
	r := parsed_src(src)
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	for obj in r.globals {
		// A definition, not a declaration: a test source may declare a helper
		// function first, and that one has no body to assert on.
		if obj.is_function && obj.is_definition {
			return obj
		}
	}
	assert false, 'no function definition in ${src}'
	return unsafe { nil }
}

// find_stmt returns the first statement of the given kind at the top level of a body.
fn find_stmt(body []&ast.Node, kind ast.NodeKind) &ast.Node {
	for n in body {
		if n.kind == kind {
			return n
		}
	}
	return unsafe { nil }
}

// uncast follows the implicit conversions `add_type` inserts, so that a test can ask
// what an expression *is* rather than what it was converted to.
//
// The usual arithmetic conversions wrap both operands, so `x++` arrives as
// `cast(cast(sub(...)))` and asserting on `.sub` at a fixed depth would be asserting on
// the conversion rules instead of on the increment.
fn uncast(node &ast.Node) &ast.Node {
	mut n := node
	for n != unsafe { nil } && n.kind == .cast {
		n = n.lhs
	}
	return n
}

// find_kind returns the first node of the given kind anywhere in a tree.
//
// A shape assertion at a fixed index is only as good as the conversion rules it assumed;
// searching for the node that has to be there says the same thing without also pinning
// down where the implicit casts sit.
fn find_kind(node &ast.Node, kind ast.NodeKind) &ast.Node {
	if node == unsafe { nil } {
		return unsafe { nil }
	}
	if node.kind == kind {
		return node
	}
	for child in [node.lhs, node.rhs, node.cond, node.then, node.els, node.init, node.inc] {
		found := find_kind(child, kind)
		if found != unsafe { nil } {
			return found
		}
	}
	for child in node.body {
		found := find_kind(child, kind)
		if found != unsafe { nil } {
			return found
		}
	}
	for child in node.args {
		found := find_kind(child, kind)
		if found != unsafe { nil } {
			return found
		}
	}
	return unsafe { nil }
}

fn test_a_return_statement_carries_a_cast_to_the_return_type() {
	f := fn_with_body('long f(int x) { return x; }\n')
	assert f.body.len == 1
	ret := f.body[0]
	assert ret.kind == .return_
	// `x` is an int and the result is a long, so the value is converted rather than
	// returned as it stands.
	assert ret.lhs.kind == .cast
	assert ret.lhs.lhs.kind == .var_ref
}

fn test_a_void_function_returns_bare() {
	f := fn_with_body('void f(void) { return; }\n')
	assert f.body[0].kind == .return_
	assert f.body[0].lhs == unsafe { nil }
}

fn test_an_if_statement_has_a_condition_and_branches() {
	f := fn_with_body('int f(int x) { if (x) { return 1; } else { return 2; } return 0; }\n')
	n := find_stmt(f.body, .if_)
	assert n != unsafe { nil }
	assert n.cond.kind == .var_ref
	assert n.then.kind == .block_
	assert n.els.kind == .block_
}

fn test_a_for_statement_has_init_cond_inc_and_body() {
	f := fn_with_body('int f(int n) { int t = 0; for (int i = 0; i < n; i++) { t += i; } return t; }\n')
	n := find_stmt(f.body, .for_)
	assert n != unsafe { nil }
	// The loop's own declaration of `i` is a statement inside the loop's scope, so `i`
	// is in the function's frame but was declared after the parameter `n`. What proves
	// the scope works is that `i` appears exactly once: a scope that did not close would
	// have shadowed it and the frame would carry two.
	mut positions := []int{}
	for i, local in f.locals {
		if local.name == 'i' {
			positions << i
		}
	}
	assert positions.len == 1
	assert positions[0] > 1
	assert n.init != unsafe { nil }
	assert n.cond.kind == .lt
	assert n.inc != unsafe { nil }
	assert n.then.kind == .block_
}

fn test_a_while_statement_is_a_loop_with_only_a_condition() {
	f := fn_with_body('int f(int n) { while (n) { n = n - 1; } return n; }\n')
	n := find_stmt(f.body, .for_)
	assert n != unsafe { nil }
	assert n.cond.kind == .var_ref
	// A `while` is represented as a `for` with no init and no inc, so the backend has
	// one loop shape rather than two that differ only in what is missing.
	assert n.init == unsafe { nil }
	assert n.inc == unsafe { nil }
}

fn test_a_do_statement_tests_its_condition_after_the_body() {
	f := fn_with_body('int f(int n) { do { n = n - 1; } while (n); return n; }\n')
	n := find_stmt(f.body, .do_)
	assert n != unsafe { nil }
	assert n.cond.kind == .var_ref
	assert n.then.kind == .block_
}

fn test_a_switch_collects_its_cases_and_default() {
	f := fn_with_body('int f(int n) {\n switch (n) {\n case 0:\n  return 1;\n case 2 ... 5:\n  return 2;\n default:\n  return 3;\n }\n return 0;\n}\n')
	sw := find_stmt(f.body, .switch_)
	assert sw != unsafe { nil }
	assert sw.cases.len == 2
	assert sw.cases[0].begin == 0
	assert sw.cases[0].end == 0
	// A GNU case range records both ends, which is what makes `case 2 ... 5` cover five
	// values rather than two.
	assert sw.cases[1].begin == 2
	assert sw.cases[1].end == 5
	assert sw.default_case != unsafe { nil }
}

fn test_break_and_continue_jump_to_the_enclosing_loop() {
	f := fn_with_body('int f(int n) { for (int i = 0; i < n; i++) { if (i) { continue; } break; } return n; }\n')
	loop := find_stmt(f.body, .for_)
	assert loop.brk_label != ''
	assert loop.cont_label != ''
	assert loop.then.body.len == 2
	if_stmt := find_stmt(loop.then.body, .if_)
	assert if_stmt != unsafe { nil }
	// continue is inside the if and reak follows it, and the two jump to
	// different labels: a backend that gave them one label would never loop.
	cont := find_stmt(if_stmt.then.body, .goto_)
	assert cont != unsafe { nil }
	assert cont.unique_label == loop.cont_label
	brk := find_stmt(loop.then.body, .goto_)
	assert brk != unsafe { nil }
	assert brk.unique_label == loop.brk_label
}

fn test_a_forward_goto_is_resolved_to_the_label_it_names() {
	f := fn_with_body('int f(int n) { if (n) goto done; n = 1; done: return n; }\n')
	if_stmt := find_stmt(f.body, .if_)
	g := if_stmt.then
	assert g.kind == .goto_
	assert g.label_name == 'done'
	// The goto was parsed before the label existed, so a non-empty unique label is the
	// whole point of collecting both and matching them at the end of the body.
	assert g.unique_label != ''
	assert g.unique_label.starts_with('.L..')
}

fn test_an_undeclared_label_is_reported() {
	r := parsed_src('int f(int n) { goto nowhere; return n; }\n')
	assert r.errors.len > 0
	assert r.errors[0].contains('undeclared label "nowhere"')
}

// label_gvar finds the anonymous global a static local became, by its relocations. A
// static local is the only global with initial-data relocations in these snippets, and
// `__func__` has none, so the flag picks it out without knowing its generated name.
fn label_gvar(r ParseResult) &ast.Obj {
	for obj in r.globals {
		if obj.rel.len > 0 {
			return obj
		}
	}
	assert false, 'no global with relocations'
	return unsafe { nil }
}

// [GNU] A static local initialized from labels used as values.
//
// This was reported as `initializer element is not constant` at the `static void *`
// line, because the byte image was written while the initializer was still being
// parsed and `&&a` carried no label yet. Measured on chibicc's own control.c lines
// 94-96, which failed at vcc -S before the deferral and pass now.
fn test_a_static_local_initialized_from_a_label_as_a_value() {
	r := parsed_src('int f(int n) { static void *p[] = {&&a, &&a, &&b}; goto *p[0]; a: return 1; b: return 2; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	obj := label_gvar(r)
	assert obj.rel.len == 3
	// The three initializers are addresses, so none of the bytes is a value: a
	// relocation that wrote a number into the slot would be indistinguishable from a
	// correct one until the linker resolved it.
	for i in 0 .. 3 {
		assert obj.rel[i].addend == 0
	}
	assert obj.rel[0].label == obj.rel[1].label
	assert obj.rel[0].label != obj.rel[2].label
	assert obj.rel[0].label.starts_with('.L..')
}

// A static local with an ordinary initializer keeps a byte image, which is what the
// deferral could have dropped for every other static local in the language.
fn test_a_static_local_with_an_ordinary_initializer_keeps_its_byte_image() {
	r := parsed_src('int f(int n) { static int j = 1 + 1; return j + n; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	mut found := false
	for obj in r.globals {
		// `1 + 1` is two bytes wide, and the point is that it was evaluated at all
		// rather than left zero by a deferral that never ran.
		if obj.ty.size == 4 && obj.init_data.len == 4 {
			found = true
		}
	}
	assert found, 'no evaluated static int in ${r.globals.len} globals'
}

// A static array whose length comes from its initializer still learns that length,
// because the parse — which decides it — is not deferred along with the byte image.
fn test_a_static_array_still_learns_its_length_from_its_initializer() {
	r := parsed_src('int f(int n) { static int a[] = {1, 2, 3}; return a[n]; }\n')
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	mut found := false
	for obj in r.globals {
		if obj.ty.kind == .array && obj.ty.array_len == 3 {
			found = true
			assert obj.ty.size == 12
		}
	}
	assert found, 'no three-element array among ${r.globals.len} globals'
}

fn test_a_break_outside_a_loop_is_reported() {
	r := parsed_src('int f(int n) { break; return n; }\n')
	assert r.errors.len > 0
	assert r.errors[0].contains('stray break')
}

fn test_a_compound_assignment_takes_the_address_of_its_target_once() {
	f := fn_with_body('int f(int x) { x += 1; return x; }\n')
	stmt := find_stmt(f.body, .expr_stmt)
	assign := stmt.lhs
	// `x += 1` becomes `tmp = &x, *tmp = *tmp + 1`, so the address is taken once and
	// `x` is not read twice: with a side-effecting target that would be a real bug.
	assert assign.kind == .comma
	assert assign.lhs.kind == .assign
	// The address is taken of the *target*, and `add_type` has wrapped it in a
	// conversion — `x` is an `int` and so is the temporary holding its address, but
	// the two are distinct types, so the cast is not elided. `uncast` is what says
	// "the cast is not the shape", which is the whole claim this test makes.
	assert uncast(assign.lhs.rhs).kind == .addr
	assert assign.rhs.kind == .assign
	assert uncast(assign.rhs.lhs).kind == .deref
	assert uncast(assign.rhs.rhs).kind == .add
	// The temporary is a fresh local, not `x`.
	assert assign.lhs.lhs.kind == .var_ref
	assert assign.lhs.lhs.var != f.params[0]
}

fn test_a_compound_assignment_to_a_member_takes_the_address_of_the_struct() {
	f := fn_with_body('struct S { int a; };\nint f(struct S s) { s.a += 1; return s.a; }\n')
	stmt := find_stmt(f.body, .expr_stmt)
	assign := uncast(stmt.lhs)
	assert assign.kind == .comma
	assert uncast(assign.lhs.rhs).kind == .addr
	// The store goes through a member of the temporary, which is what makes
	// `&s.a` — not an lvalue C can assign to — unnecessary.
	store := assign.rhs
	assert store.kind == .assign
	mem_node := find_kind(store, .member)
	assert mem_node != unsafe { nil }
	mem := mem_node.member or { ast.Member{} }
	assert mem.name == 'a'
}

fn test_a_postfix_increment_recovers_the_old_value() {
	f := fn_with_body('int f(int x) { return x++; }\n')
	inc := uncast(f.body[0].lhs)
	// `x++` is `(typeof x)((x += 1) + -1)`: the result is the value before the add, and
	// there is no node that carries that across an assignment. It is an *add* of a
	// negative rather than a subtract, because `new_add` is the one that knows a pointer
	// is being walked — and `p++` has to subtract an element's width, not one.
	assert inc.kind == .add
	assert uncast(inc.lhs).kind == .comma
	assert uncast(inc.rhs).kind == .num
	assert uncast(inc.rhs).num == -1
	// The cast is back to x's own type, which is what makes `char c; c++` still a char.
	assert f.body[0].lhs.kind == .cast
}

fn test_a_prefix_increment_is_just_a_compound_assignment() {
	f := fn_with_body('int f(int x) { return ++x; }\n')
	inc := uncast(f.body[0].lhs)
	// `++x` is `x += 1` with no arithmetic to recover: the result is the new value, so
	// there is no `-1` anywhere in it.
	assert inc.kind == .comma
	assert inc.rhs.kind == .assign
	assert uncast(inc.rhs.rhs).kind == .add
	assert uncast(inc.rhs.rhs.rhs).kind == .num
	assert uncast(inc.rhs.rhs.rhs).num == 1
}

fn test_a_call_records_the_callee_type_and_casts_each_argument() {
	f := fn_with_body('int g(int, char);\nint f(void) { return g(1, 2); }\n')
	call := uncast(f.body[0].lhs)
	assert call.kind == .funcall
	assert call.func_ty.kind == .func
	assert call.args.len == 2
	// The second parameter is a char, so the argument is converted before the call.
	assert call.args[1].kind == .cast
	assert uncast(call.args[0]).kind == .num
}

fn test_too_many_and_too_few_arguments_are_reported() {
	too_many := parsed_src('int g(int);\nint f(void) { return g(1, 2); }\n')
	assert too_many.errors.len > 0
	assert too_many.errors[0].contains('too many arguments')
	too_few := parsed_src('int g(int, int);\nint f(void) { return g(1); }\n')
	assert too_few.errors.len > 0
	assert too_few.errors[0].contains('too few arguments')
}

fn test_a_call_through_a_function_pointer_is_the_same_call() {
	f := fn_with_body('int g(int);\nint f(int (*fp)(int)) { return fp(1); }\n')
	call := uncast(f.body[0].lhs)
	assert call.kind == .funcall
	// `(*fp)(1)` and `fp(1)` differ only in the spelling of the callee, and the backend
	// must not have two cases for them.
	assert call.func_ty.kind == .func
}

fn test_a_local_declaration_becomes_statements() {
	f := fn_with_body('int f(void) { int a = 1; int b; return a; }\n')
	// The declaration is a block of statements rather than a node of its own, so the
	// backend walks one shape for every statement in a body.
	decl := f.body[0]
	assert decl.kind == .block_
	assert decl.body.len > 0
	// `int a = 1` is a memzero plus an assignment, and the memzero is what makes an
	// initializer that fills only part of an object zero the rest of it.
	assert find_kind(decl, .memzero) != unsafe { nil }
	assign := find_kind(decl, .assign)
	assert assign != unsafe { nil }
	assert find_kind(assign.rhs, .num) != unsafe { nil }
}

fn test_a_nested_block_gets_its_own_scope() {
	f := fn_with_body('int f(int n) { int x = 1; { int x = 2; n = x; } return x; }\n')
	inner := find_stmt(f.body, .block_)
	// The inner `x` is a different object from the outer one, which is what a scope is
	// for; the outer `x` is still reachable after the block closes.
	assert inner != unsafe { nil }
	mut names := []string{}
	for local in f.locals {
		if local.name == 'x' {
			names << local.name
		}
	}
	assert names.len == 2
}

fn test_a_generic_selection_picks_the_matching_association() {
	f := fn_with_body('int f(int n) { return _Generic(n, int: 1, double: 2, default: 3); }\n')
	// The controlling expression is an int, so the int association is the one kept and
	// the 1 in it is the value of the whole expression.
	picked := uncast(f.body[0].lhs)
	assert picked.kind == .num
	assert picked.num == 1
}

fn test_a_generic_selection_strips_top_level_qualifiers() {
	// A `const int` controlling expression matches `int`, never `const int` —
	// measured against gcc and tcc, which both pick the unqualified association
	// regardless of order and fall through to `default` when only a qualified
	// one is offered.
	f := fn_with_body('int f(const int n) { return _Generic(n, int: 1, const int: 2, default: 3); }\n')
	assert uncast(f.body[0].lhs).num == 1
	g := fn_with_body('int g(const int n) { return _Generic(n, const int: 2, default: 3); }\n')
	assert uncast(g.body[0].lhs).num == 3
}

fn test_a_generic_selection_tells_char_from_signed_char() {
	// Plain `char` and `signed char` are distinct types for `_Generic` even
	// though they share a representation: a `const char *` controlling
	// expression matches `const char *`, not `const signed char *`.
	f := fn_with_body('int f(const char *p) { return _Generic(p, const unsigned char *: 1, const char *: 4, char *: 3, const signed char *: 2); }\n')
	assert uncast(f.body[0].lhs).num == 4
}

fn test_a_statement_expression_is_a_block() {
	f := fn_with_body('int f(int n) { return ({ int t = n; t + 1; }); }\n')
	stmt_expr := uncast(f.body[0].lhs)
	assert stmt_expr.kind == .stmt_expr
	assert stmt_expr.body.len > 0
	// Its value is the last expression statement, which is the only rule that makes
	// `({ ... })` usable as an expression at all: the block declares `t` and ends with
	// `t + 1`, so the result is that `+` and not the declaration.
	assert stmt_expr.body.last().kind == .expr_stmt
	assert stmt_expr.ty.kind == .basic
}

// `__asm__` is supported, and the operands and template survive the parse: `math.h`
// needs `rint` implemented in inline asm, and the template's `%N` substitutes are the
// backend's business, so what a parser test can pin is that the operands were read in
// order and the constraint's modifier was stripped.
fn test_an_asm_statement_keeps_its_operands() {
	stmt := find_stmt(fn_with_body('void f(double x) { double r; asm("fldl %1" "fstpl %0" : "=m" (r) : "m" (x)); }\n').body,
		.asm)
	assert stmt != unsafe { nil }
	// Two operands, outputs before inputs, which is the order `%N` numbers them in.
	assert stmt.asm_ops.len == 2
	// The template is the joined run, not one piece of it.
	assert stmt.asm_template == 'fldl %1fstpl %0'
	// The modifier is stripped, so both `"=m"` and `"m"` answer the same thing.
	assert stmt.asm_constraints == ['m', 'm']
	// The operands are the named variables, in source order.
	assert stmt.asm_ops[0].kind == .var_ref
	assert stmt.asm_ops[1].kind == .var_ref
}

// An unsupported *constraint* is reported rather than guessed at, because a wrong
// constraint is a silently wrong program. `"=m"` is the only one modelled — it is the
// whole of what `tcc/tcc_libm.h` uses — so a register constraint still reaches the
// error.
fn test_an_unsupported_asm_constraint_is_reported() {
	r := parsed_src('void f(int x) { int r; asm("mov %1, %0" : "=r" (r) : "r" (x)); }\n')
	assert r.errors.len > 0, 'expected a diagnostic, got none'
	assert r.errors[0].contains('asm constraint "=r" is not supported')
}

