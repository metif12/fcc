module fcc

import src.ast

// Tests for constant-expression evaluation of addresses and members.
// These pin the member-of-global address fix (initializer.c:25).

fn test_member_of_global_address_is_constant() {
	// `g30.a.a` is an array member of a member of a global: its address is
	// a link-time constant, so `int *g31 = g30.a.a;` must compile.
	src := 'struct { struct { int a[3]; } a; } g30 = {{{1,2,3}}}; int *g31 = g30.a.a; int main(void) { return g31[0] == 1 && g31[1] == 2 && g31[2] == 3 ? 0 : 1; }'
	mut p := preprocessor([]string{}, []string{})
	p.define_builtins()
	pre := p.run_text(src, 't.c')
	assert pre.errors.len == 0, pre.errors.join('\n')
	parsed := parse_tokens(pre.tokens, 't.c', p.packs)
	assert parsed.errors.len == 0, parsed.errors.join('\n')
	assert parsed.globals.len > 0
	// g31's initializer must be a relocation (address), not a plain zero.
	mut g31 := &ast.Obj(unsafe { nil })
	for obj in parsed.globals {
		if obj.name == 'g31' {
			g31 = obj
		}
	}
	assert g31 != unsafe { nil }
	assert g31.rel.len == 1, 'g31 must be a relocation, got ${g31.rel.len}'
	assert g31.rel[0].label == 'g30'
}
