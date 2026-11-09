module core

fn test_blip_desugar_task_block() {
	blip := 'task "build" {\n  run = "fcc"\n}\n'
	out := desugar_blip(blip)
	assert out.contains('[task."build"]')
	assert out.contains('run = "fcc"')
	assert !out.contains('}')
}

fn test_blip_desugar_build_block() {
	out := desugar_blip('build {\n  target = "x86_64-windows"\n}\n')
	assert out.contains('[build]')
}

fn test_parse_toml_config() {
	cfg := parse_config_text('[build]\ntarget = "x86_64-linux"\nstd = "gnu11"\ninputs = ["main.c"]\n', 'fcc.toml')!
	assert cfg.target == 'x86_64-linux'
	assert cfg.inputs == ['main.c']
}

fn test_parse_blip_config() {
	cfg := parse_config_text('build {\n  target = "x86_64-linux"\n}\n', 'fcc.blip')!
	assert cfg.target == 'x86_64-linux'
}

fn test_parse_blip_task() {
	cfg := parse_config_text('task "build" {\n  run = "fcc -S"\n}\n', 'build.blip')!
	assert 'build' in cfg.tasks
	assert cfg.tasks['build'].run == 'fcc -S'
}

fn test_plugin_registry_roundtrip() {
	reset_registries()
	reset_commands()
	register_input(TestInput{})
	register_output(TestOutput{})
	register_hook(TestHook{})
	register_command(CliCommand{
		name:        'test-cmd'
		description: 'test'
		handler:     fn (args []string, cfg FccConfig) int {
			return 0
		}
	})
	assert find_input('x.c') or { panic('no input') }.name() == 'test-in'
	assert find_output('asm') or { panic('no output') }.name() == 'test-out'
	assert list_hooks().len == 1
	assert find_command('test-cmd') or { panic('no cmd') }.name == 'test-cmd'
	assert dispatch_verb(['test-cmd'], default_config()) == 0
	assert dispatch_verb(['--help'], default_config()) == -1
	reset_registries()
	reset_commands()
}

struct TestInput {}

fn (p TestInput) name() string {
	return 'test-in'
}

fn (p TestInput) extensions() []string {
	return ['.c']
}

fn (p TestInput) can_handle(path string) bool {
	return true
}

fn (p TestInput) load(path string, mut ctx PipelineContext) ! {
	ctx.inputs << path
}

struct TestOutput {}

fn (p TestOutput) name() string {
	return 'test-out'
}

fn (p TestOutput) formats() []string {
	return ['asm']
}

fn (p TestOutput) emit(mut ctx PipelineContext) ! {
	ctx.units << 'out'
}

struct TestHook {}

fn (p TestHook) name() string {
	return 'test-hook'
}

fn (p TestHook) stage() Stage {
	return .pre_parse
}

fn (p TestHook) priority() int {
	return 0
}

fn (p TestHook) run(mut ctx PipelineContext) ! {
	ctx.data['hook'] = 'ran'
}

fn test_run_hooks_and_pipeline() {
	reset_registries()
	register_input(TestInput{})
	register_output(TestOutput{})
	register_hook(TestHook{})
	mut ctx := PipelineContext{
		emit: 'asm'
	}
	run_pipeline(mut ctx, ['a.c'])!
	assert ctx.inputs == ['a.c']
	assert ctx.units == ['out']
	assert ctx.data['hook'] == 'ran'
	reset_registries()
}

__global test_order []string

fn test_task_runner_orders_deps_and_detects_cycle() {
	test_order = []string{}
	tasks := {
		'a': TaskDef{
			run:     'echo a'
			depends: ['b']
		}
		'b': TaskDef{ run: 'echo b' }
	}
	run_tasks(tasks, ['a'], fn (run string) int {
		test_order << run
		return 0
	}) or { panic(err.msg()) }
	assert test_order == ['echo b', 'echo a']
	bad := {
		'x': TaskDef{
			run:     'echo x'
			depends: ['x']
		}
	}
	if _ := run_tasks_ids(bad) {
		assert false, 'expected cycle error'
	}
}

fn run_tasks_ids(tasks map[string]TaskDef) ! {
	run_tasks(tasks, ['x'], fn (run string) int {
		return 0
	})!
}

fn test_parse_plugin_declaration_keys() {
	cfg := parse_config_text('[plugin."wlang"]\ncommand = "wlang-transpile"\nkind = "input"\nextensions = [".w", ".wat"]\n[plugin."greet"]\ncommand = "echo hi"\n', 'fcc.toml')!
	assert cfg.plugins['wlang'].command == 'wlang-transpile'
	assert cfg.plugins['wlang'].kind == 'input'
	assert cfg.plugins['wlang'].extensions == ['.w', '.wat']
	assert cfg.plugins['wlang'].enabled == true
	assert cfg.plugins['greet'].command == 'echo hi'
	assert cfg.plugins['greet'].kind == ''
}

fn test_parse_plugin_enabled_flag() {
	cfg := parse_config_text('[plugin."bf"]\nenabled = false\n', 'fcc.toml')!
	assert cfg.plugins['bf'].enabled == false
	assert is_plugin_disabled('bf', cfg)
	assert !is_plugin_disabled('other', cfg)
}

fn test_apply_config_disables_find_and_hooks() {
	reset_registries()
	reset_commands()
	register_input(TestInput{})
	register_output(TestOutput{})
	register_hook(TestHook{})
	assert find_input('x.c') or { panic('no input') }.name() == 'test-in'
	assert find_output('asm') or { panic('no output') }.name() == 'test-out'
	mut ctx := PipelineContext{
		emit: 'asm'
	}
	run_hooks(.pre_parse, mut ctx)!
	assert ctx.data['hook'] == 'ran'

	mut cfg := default_config()
	cfg.disabled = ['test-in', 'test-out', 'test-hook']
	apply_config(cfg)
	assert find_input('x.c') == none
	assert find_output('asm') == none
	mut ctx2 := PipelineContext{
		emit: 'asm'
	}
	run_hooks(.pre_parse, mut ctx2)!
	assert ctx2.data['hook'] == ''
	assert input_claimed_by_disabled('x.c')
	assert !input_claimed_by_disabled('y.z')
	reset_registries()
	reset_commands()
}

fn test_dispatch_skips_disabled_command() {
	reset_registries()
	reset_commands()
	register_command(CliCommand{
		name:        'test-cmd2'
		description: 'test'
		handler:     fn (args []string, cfg FccConfig) int {
			return 7
		}
	})
	assert dispatch_verb(['test-cmd2'], default_config()) == 7
	mut cfg := default_config()
	cfg.disabled = ['test-cmd2']
	assert dispatch_verb(['test-cmd2'], cfg) == -1
	reset_registries()
	reset_commands()
}

fn test_dispatch_runs_config_command() {
	reset_registries()
	reset_commands()
	mut cfg := default_config()
	cfg.plugins['greet'] = PluginDef{
		command: 'echo hi'
	}
	assert dispatch_verb(['greet', 'there'], cfg) == 0
	assert dispatch_verb(['missing'], cfg) == -1
	reset_registries()
	reset_commands()
}
