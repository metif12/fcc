module ext

import os
import src.core

// The plugin pipeline's -c path: C input through the default input plugin,
// out through the default object plugin (native phase-3 emission, no `as`).
// This is the same coverage tools/objtest gives the driver path, scoped to
// one small program so it stays inside `v test`.

const tiny_c = 'int add(int a, int b) { return a + b; }
int main(void) { return add(40, 2); }
'

fn test_plugin_pipeline_compiles_to_object() {
	dir := os.join_path(os.temp_dir(), 'fcc_ext_test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	src := os.join_path(dir, 'tiny.c')
	obj := os.join_path(dir, 'tiny.o')
	os.write_file(src, tiny_c) or { panic(err.msg()) }
	defer {
		os.rm(src) or {}
		os.rm(obj) or {}
	}

	core.reset_registries()
	register_defaults()
	register_extra_outputs()

	mut ctx := core.PipelineContext{
		inputs: [src]
		output: obj
		emit:   'o'
	}
	p := core.find_input(src) or { panic('no input plugin for .c') }
	p.load(src, mut ctx) or { panic('input plugin failed: ${err.msg()}') }
	if ctx.failed {
		panic('frontend failed: ${ctx.diagnostics.join('\n')}')
	}
	o := core.find_output('o') or { panic('no output plugin for o') }
	o.emit(mut ctx) or { panic('output plugin failed: ${err.msg()}') }
	assert os.is_file(obj)
	// The object must name main as an external text symbol; anything else
	// (missing relocations, wrong machine) fails the link, not this assert.
	info := os.execute('objdump -t ${obj}')
	assert info.exit_code == 0
	assert info.output.contains('main')
}
