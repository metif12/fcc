module driver

import src.core

fn parse_opts(args []string) Options {
	return parse_args(args) or { panic('unexpected parse failure for ${args}: ${err.msg()}') }
}

fn test_emit_flag_parses_joined_and_separated() {
	o := parse_opts(['--emit', 'asm=x.s', 'a.c'])
	assert o.emits == ['asm=x.s']
	o2 := parse_opts(['--emit=obj=y.o', 'a.c'])
	assert o2.emits == ['obj=y.o']
}

fn test_canonical_emit_format_spellings() {
	assert canonical_emit_format('asm')! == 'asm'
	assert canonical_emit_format('s')! == 'asm'
	assert canonical_emit_format('S')! == 'asm'
	assert canonical_emit_format('obj')! == 'obj'
	assert canonical_emit_format('o')! == 'obj'
	assert canonical_emit_format('tokens')! == 'tokens'
	assert canonical_emit_format('preprocessed')! == 'preprocessed'
	assert canonical_emit_format('E')! == 'preprocessed'
	assert canonical_emit_format('ast')! == 'ast'
	assert canonical_emit_format('to-v')! == 'v'
	assert canonical_emit_format('v-bindings')! == 'v-bindings'
	if _ := canonical_emit_format('exe') {
		assert false, 'exe must be rejected'
	} else {
		assert err.msg().contains('not supported')
	}
	if _ := canonical_emit_format('wat') {
		assert false, 'wat must be rejected'
	} else {
		assert err.msg().contains('unknown emit format')
	}
}

fn test_stem_for_uses_first_input() {
	assert stem_for([]string{}) == 'out'
	assert stem_for(['main.c']) == 'main'
	assert stem_for(['a.b.c', 'd.c']) == 'a.b'
	assert stem_for(['Makefile']) == 'Makefile'
}

fn test_resolve_empty_without_emit_or_config() {
	o := parse_opts(['-S', 'a.c'])
	reqs := resolve_outputs(&o, core.default_config())!
	assert reqs.len == 0
}

fn test_resolve_single_emit_uses_dash_o() {
	o := parse_opts(['--emit', 'asm', '-o', 'x.s', 'a.c'])
	reqs := resolve_outputs(&o, core.default_config())!
	assert reqs.len == 1
	assert reqs[0].format == 'asm'
	assert reqs[0].path == 'x.s'
}

fn test_resolve_multi_emit_uses_stems() {
	o := parse_opts(['--emit', 'asm', '--emit', 'obj', 'main.c'])
	reqs := resolve_outputs(&o, core.default_config())!
	assert reqs.len == 2
	assert reqs[0].format == 'asm'
	assert reqs[0].path == 'main.s'
	assert reqs[1].format == 'obj'
	assert reqs[1].path == 'main.o'
}

fn test_resolve_emit_path_beats_stem() {
	o := parse_opts(['--emit', 'asm=out.s', '--emit', 'obj', 'main.c'])
	reqs := resolve_outputs(&o, core.default_config())!
	assert reqs[0].path == 'out.s'
	assert reqs[1].path == 'main.o'
}

fn test_resolve_config_outputs_fill_gaps() {
	mut cfg := core.default_config()
	cfg.outputs['obj'] = core.OutputDef{
		path: 'cfg.o'
	}
	o := parse_opts(['--emit', 'obj', 'main.c'])
	reqs := resolve_outputs(&o, cfg)!
	assert reqs.len == 1
	assert reqs[0].path == 'cfg.o'
}

fn test_resolve_config_only_lists_sorted() {
	mut cfg := core.default_config()
	cfg.outputs['obj'] = core.OutputDef{
		path: 'b.o'
	}
	cfg.outputs['asm'] = core.OutputDef{
		path: 'a.s'
	}
	o := parse_opts(['main.c'])
	reqs := resolve_outputs(&o, cfg)!
	assert reqs.len == 2
	assert reqs[0].format == 'asm'
	assert reqs[0].path == 'a.s'
	assert reqs[1].format == 'obj'
	assert reqs[1].path == 'b.o'
}

fn test_resolve_rejects_mode_flag_mix() {
	o := parse_opts(['-S', '--emit', 'obj=x.o', 'main.c'])
	if _ := resolve_outputs(&o, core.default_config()) {
		assert false, '-S with --emit must fail'
	} else {
		assert err.msg().contains('cannot combine')
	}
}

fn test_resolve_rejects_unknown_format() {
	o := parse_opts(['--emit', 'wat', 'main.c'])
	if _ := resolve_outputs(&o, core.default_config()) {
		assert false, 'unknown format must fail'
	} else {
		assert err.msg().contains('unknown emit format')
	}
}

fn test_resolve_rejects_unknown_config_format() {
	mut cfg := core.default_config()
	cfg.outputs['wat'] = core.OutputDef{
		path: 'x'
	}
	o := parse_opts(['main.c'])
	if _ := resolve_outputs(&o, cfg) {
		assert false, 'unknown config format must fail'
	} else {
		assert err.msg().contains('unknown output format')
	}
}
