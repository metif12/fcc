module ast

// Expression/statement classification, traversal and direct construction for
// input plugins.
//
// The C front end is one producer of this AST; language plugins (Brainfuck,
// Bash, and third-party inputs behind `core.InputPlugin`) are others. Three
// ideas are borrowed from compilers that have solved the multi-language
// problem already:
//
//   - Go `go/ast`: `Expr`/`Stmt` node categories and one shared traversal,
//     `ast.Inspect`, so tools never hand-roll recursion. That is `class`,
//     `children` and `walk` here, with a `Visitor` interface because this V
//     build silently drops closure captures coerced to `fn` parameters —
//     a callback API would compile and then visit nothing.
//   - V's own AST: one small struct per node shape behind a sum type, so the
//     compiler rejects an unhandled shape. V's build here cannot express that
//     (see the note in token.v), so the flat `Node` stays — but `class` gives
//     back the category dispatch, and `build.v` gives back the safe
//     constructors.
//   - Zig `std.zig.Ast` / Odin: a node is a tag plus payload, and provenance
//     (which language produced it) travels with the node. That is `lang` and
//     the `.plugin` kind: a plugin builds nodes directly instead of
//     round-tripping through C text, and a `post_parse` hook lowers them
//     before codegen.

// NodeClass is the syntactic category of a node kind.
//
// Go splits these into three interfaces (`Expr`, `Stmt`, `Decl`); here
// declarations are `Obj`, not nodes, so two classes plus `other` cover the
// set. The backend and the constant folder dispatch on `kind`, not on this —
// `class` is for generic tools (dumpers, linters, plugin lowerings) that need
// to tell "evaluates to a value" from "does something" without listing sixty
// kinds.
pub enum NodeClass {
	expr
	stmt
	other
}

// class reports the syntactic category of a node kind.
//
// Every variant is listed explicitly rather than defaulting, so adding a kind
// to `NodeKind` breaks this match until the new kind is classified — the same
// guarantee V's sum types give, spelled as a compiler error here.
pub fn (k NodeKind) class() NodeClass {
	return match k {
		.null_expr, .num, .num_stmt, .var_ref, .add, .sub, .mul, .div, .mod,
		.neg, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .le,
		.assign, .cond_expr, .comma, .member, .addr, .deref, .not, .bit_not,
		.log_and, .log_or, .funcall, .cast, .stmt_expr, .compound_literal,
		.vla_ptr, .va_arg_, .generic, .plugin {
			NodeClass.expr
		}
		.return_, .if_, .for_, .do_, .switch_, .case_, .block_, .expr_stmt,
		.null_stmt, .decl_stmt, .memzero, .va_start_, .goto_, .goto_expr,
		.label, .asm {
			NodeClass.stmt
		}
	}
}

// is_expr reports whether the node evaluates to a value.
pub fn (n &Node) is_expr() bool {
	if n == unsafe { nil } {
		return false
	}
	return n.kind.class() == .expr
}

// is_stmt reports whether the node is a statement.
pub fn (n &Node) is_stmt() bool {
	if n == unsafe { nil } {
		return false
	}
	return n.kind.class() == .stmt
}

// children returns the child nodes of n in evaluation order.
//
// The order is fixed (operands, condition, branches, loop parts, block body,
// call arguments) so a walk that prints or rewrites is deterministic. Nil
// slots are skipped, so callers never nil-check.
pub fn children(n &Node) []&Node {
	if n == unsafe { nil } {
		return []&Node{}
	}
	mut out := []&Node{}
	if n.lhs != unsafe { nil } {
		out << n.lhs
	}
	if n.rhs != unsafe { nil } {
		out << n.rhs
	}
	if n.cond != unsafe { nil } {
		out << n.cond
	}
	if n.then != unsafe { nil } {
		out << n.then
	}
	if n.els != unsafe { nil } {
		out << n.els
	}
	if n.init != unsafe { nil } {
		out << n.init
	}
	if n.inc != unsafe { nil } {
		out << n.inc
	}
	// Loops (`for_`, `do_`) carry their body in `then`; blocks, switches and
	// cases carry theirs in `body`. Both are covered.
	for b in n.body {
		out << b
	}
	for c in n.cases {
		out << c
	}
	if n.default_case != unsafe { nil } {
		out << n.default_case
	}
	for a in n.args {
		out << a
	}
	for o in n.asm_ops {
		out << o
	}
	return out
}

// Visitor is the hook walk calls on every node.
//
// An interface rather than a callback: this V build silently drops closure
// captures coerced to `fn` parameters (a callback API compiles, then visits
// nothing), while interface dispatch is what `core`'s plugin registries
// already rely on. Return false from `visit` to prune that node's children
// but not its siblings.
pub interface Visitor {
mut:
	visit(n &Node) bool
}

// MutVisitor is not provided on purpose.
//
// Reads go through `Visitor`/`walk`. A mutating twin would need the node as
// a `mut` interface parameter, and interface dispatch with a mutable
// reference parameter segfaults on this V build (measured, same family as
// the dropped closure captures above). Rewrites instead collect first and
// mutate after: `collect_all` gathers every node below a root into a plain
// slice, and a `for mut` loop — the same pattern `resolve_goto_labels` uses —
// edits them. No interface, no crash.
pub fn collect_all(n &Node, mut out []&Node) {
	if n == unsafe { nil } {
		return
	}
	out << n
	for c in children(n) {
		collect_all(c, mut out)
	}
}

// collect_roots gathers every node below every root, in order.
pub fn collect_roots(nodes []&Node, mut out []&Node) {
	for n in nodes {
		collect_all(n, mut out)
	}
}

// walk visits n and every node below it, preorder.
//
// Generic tools should walk: the front end's passes each recurse by hand,
// which means a plugin that adds a shape has to find every recursion.
pub fn walk(n &Node, mut v Visitor) {
	if n == unsafe { nil } {
		return
	}
	if !v.visit(n) {
		return
	}
	for c in children(n) {
		walk(c, mut v)
	}
}

// walk_all walks every root in order.
pub fn walk_all(nodes []&Node, mut v Visitor) {
	for n in nodes {
		walk(n, mut v)
	}
}

// KindCounter counts nodes of one kind. It exists because a counting closure
// cannot capture its counter on this toolchain (see `Visitor`); a struct with
// a `kind` field does the same job without captures.
pub struct KindCounter {
pub:
	kind NodeKind
pub mut:
	n int
}

// visit implements Visitor, counting nodes of the configured kind.
pub fn (mut c KindCounter) visit(n &Node) bool {
	if n.kind == c.kind {
		c.n++
	}
	return true
}

// count_kind returns how many nodes under n (inclusive) have the given kind.
pub fn count_kind(n &Node, kind NodeKind) int {
	mut c := KindCounter{
		kind: kind
	}
	walk(n, mut c)
	return c.n
}
