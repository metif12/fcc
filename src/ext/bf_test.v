module ext

import os
import src.core

// Tests for the example Brainfuck language plugin (src/ext/bf.v).

fn test_bf_transpiles_cells_and_pointer() {
	c := transpile_bf('++>+++<-', 't.bf')!
	assert c.contains('unsigned char bf_tape[30000];')
	assert c.contains('unsigned char *bf_ptr = bf_tape;')
	assert c.contains('++*bf_ptr;')
	assert c.contains('--*bf_ptr;')
	assert c.contains('++bf_ptr;')
	assert c.contains('--bf_ptr;')
	assert c.contains('return 0;')
}

fn test_bf_transpiles_loops_and_io() {
	c := transpile_bf('[.,]', 't.bf')!
	assert c.contains('while (*bf_ptr) {')
	assert c.contains('putchar(*bf_ptr);')
	assert c.contains('*bf_ptr = getchar();')
}

fn test_bf_ignores_non_commands() {
	a := transpile_bf('+++ hello +++', 't.bf')!
	b := transpile_bf('++++++', 't.bf')!
	assert a == b
}

fn test_bf_rejects_unbalanced_brackets() {
	if _ := transpile_bf('++[>++', 't.bf') {
		assert false, 'expected an unclosed [ error'
	} else {
		assert err.msg().contains('unclosed')
		assert err.msg().contains('t.bf:1:3')
	}
	if _ := transpile_bf('++]', 't.bf') {
		assert false, 'expected an unmatched ] error'
	} else {
		assert err.msg().contains('unmatched')
	}
}

fn test_bf_pipeline_compiles_to_object() {
	// `++++++[>++++++++<-]>.` computes 6*8 = 48 and prints it: ASCII '0'.
	// The pipeline path is load (transpile + parse) then native -c.
	dir := os.join_path(os.temp_dir(), 'fcc_bf_test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	src := os.join_path(dir, 'zero.bf')
	obj := os.join_path(dir, 'zero.o')
	os.write_file(src, '++++++[>++++++++<-]>.') or { panic(err.msg()) }
	defer {
		os.rm(src) or {}
		os.rm(obj) or {}
	}

	core.reset_registries()
	register_defaults()
	register_extra_outputs()
	register_bf()

	p := core.find_input(src) or { panic('no input plugin for .bf') }
	assert p.name() == 'example-bf-input'
	mut ctx := core.PipelineContext{
		inputs: [src]
		output: obj
		emit:   'o'
	}
	p.load(src, mut ctx) or { panic('bf input plugin failed: ${err.msg()}') }
	if ctx.failed {
		panic('frontend failed: ${ctx.diagnostics.join('\n')}')
	}
	o := core.find_output('o') or { panic('no output plugin for o') }
	o.emit(mut ctx) or { panic('output plugin failed: ${err.msg()}') }
	assert os.is_file(obj)
	info := os.execute('objdump -t ${obj}')
	assert info.exit_code == 0
	assert info.output.contains('main')
	assert info.output.contains('bf_tape')
}
