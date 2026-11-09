module ast

// Tests for the language-neutral AST surface: classification, traversal and
// direct construction. These pin the contract input plugins program against.

fn test_class_splits_expr_from_stmt() {
	assert NodeKind.add.class() == .expr
	assert NodeKind.funcall.class() == .expr
	assert NodeKind.if_.class() == .stmt
	assert NodeKind.for_.class() == .stmt
	assert NodeKind.return_.class() == .stmt
	assert NodeKind.plugin.class() == .expr
}

fn test_is_expr_and_is_stmt_agree_with_class() {
	mut n := &Node{
		kind: .add
		lang: 'c'
	}
	assert n.is_expr()
	assert !n.is_stmt()
	n.kind = .if_
	assert n.is_stmt()
	assert !n.is_expr()
	mut nil_node := &Node(unsafe { nil })
	assert !nil_node.is_expr()
	assert !nil_node.is_stmt()
}

fn int_ty() &Type {
	return &Type{
		kind:  .basic
		basic: .int_
		size:  4
		align: 4
	}
}

fn test_builders_set_lang_and_shape() {
	ty := int_ty()
	tok := synth_tok('bash')
	a := num_node(1, ty, tok, 'bash')
	b := num_node(2, ty, tok, 'bash')
	sum := binary_node(.add, a, b, ty, tok, 'bash')
	assert sum.lang == 'bash'
	assert sum.lhs.num == 1
	assert sum.rhs.num == 2
	assert sum.is_expr()
	assert !sum.is_stmt()

	st := expr_stmt_node(sum, tok, 'bash')
	assert st.is_stmt()
	assert st.lang == 'bash'

	blk := block_node([st], tok, 'bash')
	assert blk.body.len == 1

	ret := return_node(sum, tok, 'bash')
	assert ret.kind == .return_

	cond := if_node(sum, blk, unsafe { nil }, tok, 'bash')
	assert cond.cond == sum
	assert cond.then == blk
	assert cond.els == unsafe { nil }
}

// KindCollector gathers visited kinds in order.
struct KindCollector {
mut:
	kinds []NodeKind
}

fn (mut c KindCollector) visit(n &Node) bool {
	c.kinds << n.kind
	return true
}

fn test_walk_visits_every_node_preorder() {
	ty := int_ty()
	tok := synth_tok('t')
	a := num_node(1, ty, tok, 'bash')
	b := num_node(2, ty, tok, 'bash')
	sum := binary_node(.add, a, b, ty, tok, 'bash')
	st := expr_stmt_node(sum, tok, 'bash')
	blk := block_node([st], tok, 'bash')

	mut c := KindCollector{}
	walk(blk, mut c)
	assert c.kinds == [NodeKind.block_, .expr_stmt, .add, .num, .num]
}

// Pruner counts visits and never descends into `.add` subtrees.
struct Pruner {
mut:
	seen int
}

fn (mut p Pruner) visit(n &Node) bool {
	p.seen++
	return n.kind != .add
}

fn test_walk_prunes_on_false() {
	ty := int_ty()
	tok := synth_tok('t')
	a := num_node(1, ty, tok, 'bash')
	b := binary_node(.add, num_node(2, ty, tok, 'bash'), num_node(3, ty, tok, 'bash'),
		ty, tok, 'bash')
	top := binary_node(.mul, a, b, ty, tok, 'bash')

	mut p := Pruner{}
	walk(top, mut p)
	// mul, 1, add — the add's children are pruned.
	assert p.seen == 3
}

fn test_children_skips_nil_slots() {
	ty := int_ty()
	tok := synth_tok('t')
	n := if_node(num_node(1, ty, tok, 'bash'), unsafe { nil }, unsafe { nil }, tok,
		'bash')
	kids := children(n)
	assert kids.len == 1
	assert kids[0].kind == .num
}

fn test_plugin_node_carries_payload() {
	tok := synth_tok('my-lang')
	mut data := map[string]string{}
	data['op'] = 'print'
	n := plugin_node('my-lang', data, tok, 'my-lang')
	assert n.kind == .plugin
	assert n.plugin == 'my-lang'
	assert n.plugin_data['op'] == 'print'
	assert n.lang == 'my-lang'
	assert n.is_expr()
}

fn test_count_kind_counts_matching_nodes() {
	ty := int_ty()
	tok := synth_tok('t')
	tree := binary_node(.add, num_node(1, ty, tok, 'bash'), num_node(2, ty, tok, 'bash'),
		ty, tok, 'bash')
	assert count_kind(tree, .num) == 2
	assert count_kind(tree, .add) == 1
	assert count_kind(tree, .mul) == 0
}

fn test_objs_for_plugin_symbols() {
	ty := int_ty()
	v := var_obj('x', ty)
	assert v.name == 'x'
	assert !v.is_function
	f := func_obj('main', ty, [v])
	assert f.is_function
	assert f.params.len == 1
}

fn test_plugin_type_is_opaque_and_attributed() {
	ty := plugin_type('bash-string', 'bash')
	assert ty.kind == .plugin
	assert ty.plugin == 'bash-string'
	assert ty.lang == 'bash'
	// Incomplete until the plugin measures it, so the C size logic refuses it.
	assert !ty.is_complete()
	assert ty.size_or_known() == none
}

fn test_objs_inherit_type_lang() {
	ty := plugin_type('bash-string', 'bash')
	v := var_obj('s', ty)
	assert v.lang == 'bash'
	f := func_obj('greet', ty, [])
	assert f.lang == 'bash'
	n := var_ref_node(v, synth_tok('bash'), 'bash')
	assert n.ty == ty
	assert n.lang == 'bash'
}

fn test_tokens_carry_lang() {
	mut t := synth_tok('echo')
	assert t.text == 'echo'
	t.lang = 'bash'
	assert t.lang == 'bash'
}

fn test_plugin_nodes_walk_like_plain_ones() {
	ty := plugin_type('bash-string', 'bash')
	tok := synth_tok('bash')
	mut data := map[string]string{}
	data['op'] = 'print'
	p := plugin_node('bash', data, tok, 'bash')
	st := expr_stmt_node(p, tok, 'bash')
	assert count_kind(st, .plugin) == 1
	assert count_kind(st, .expr_stmt) == 1
	kids := children(st)
	assert kids.len == 1
	assert kids[0].plugin == 'bash'
}

fn test_collect_all_gathers_every_node_for_rewriting() {
	ty := int_ty()
	tok := synth_tok('t')
	tree := binary_node(.add, num_node(1, ty, tok, 'bash'), num_node(2, ty, tok, 'bash'),
		ty, tok, 'bash')
	mut flat := []&Node{}
	collect_all(tree, mut flat)
	assert flat.len == 3
	// Collected references are live: editing through them rewrites the tree.
	for mut n in flat {
		n.lang = 'rewritten'
	}
	assert tree.lang == 'rewritten'
	assert tree.lhs.lang == 'rewritten'
	assert tree.rhs.lang == 'rewritten'
}
