module ext

import os
import src.core

// Default CLI plugin: every `fcc <verb>` is a registered command.
// The historic `fcc [options] file...` form stays as the fallback in
// driver.main (back-compat), documented here as `default-cli`.

pub fn register_cli() {
	core.register_command(core.CliCommand{
		name:        'build'
		usage:       'fcc build [task] [--config fcc.toml]'
		description: 'run build.blip / build.toml tasks, or delegate to build.v'
		handler:     cmd_build
	})
	core.register_command(core.CliCommand{
		name:        'plugin'
		usage:       'fcc plugin list'
		description: 'list registered input/output/hook/CLI plugins'
		handler:     cmd_plugin
	})
	core.register_command(core.CliCommand{
		name:        'config'
		usage:       'fcc config show'
		description: 'show effective configuration (file + defaults)'
		handler:     cmd_config
	})
	core.register_command(core.CliCommand{
		name:        'init'
		usage:       'fcc init [--blip]'
		description: 'write starter fcc.toml / build.blip / build.v'
		handler:     cmd_init
	})
}

fn cmd_build(args []string, cfg core.FccConfig) int {
	dir := os.getwd()
	// build.v wins when present (programmatic, like build.zig).
	if os.is_file(os.join_path(dir, 'build.v'))
		&& !os.is_file(os.join_path(dir, 'build.blip'))
		&& !os.is_file(os.join_path(dir, 'build.toml')) {
		if core.delegate_build_v(dir, args) {
			return 0
		}
	}
	// Declarative tasks: merge config-file tasks (none extra here; cfg holds them).
	if cfg.tasks.len == 0 {
		eprintln('fcc build: no tasks (add build.blip or [task.*] in fcc.toml, or build.v)')
		return 1
	}
	targets := args.filter(!it.starts_with('-'))
	core.run_tasks(cfg.tasks, targets, fn (run string) int {
		if run == '' {
			return 0
		}
		r := os.execute(run)
		print(r.output)
		return r.exit_code
	}) or {
		eprintln(err.msg())
		return 1
	}
	return 0
}

fn cmd_plugin(args []string, cfg core.FccConfig) int {
	if args.len == 0 || args[0] == 'list' {
		println('inputs:')
		for p in core.list_inputs() {
			disabled := if core.is_plugin_disabled(p.name(), cfg) { ' [disabled]' } else { '' }
			println('  ${p.name()}${disabled}  ext=${p.extensions()}')
		}
		println('outputs:')
		for p in core.list_outputs() {
			disabled := if core.is_plugin_disabled(p.name(), cfg) { ' [disabled]' } else { '' }
			println('  ${p.name()}${disabled}  fmt=${p.formats()}')
		}
		println('hooks:')
		for p in core.list_hooks() {
			disabled := if core.is_plugin_disabled(p.name(), cfg) { ' [disabled]' } else { '' }
			println('  ${p.name()}${disabled}  stage=${p.stage()} prio=${p.priority()}')
		}
		println('commands:')
		for c in core.list_commands() {
			println('  ${c.name}  ${c.description}')
		}
		println('(external: any fcc-<verb> on PATH is also a command)')
		return 0
	}
	eprintln('usage: fcc plugin list')
	return 1
}

fn cmd_config(args []string, cfg core.FccConfig) int {
	if args.len > 0 && args[0] == 'show' {
		println('source: ${if cfg.source == '' { '(defaults)' } else { cfg.source }}')
		println('target: ${cfg.target}')
		println('std: ${cfg.std}')
		println('emit: ${cfg.emit}')
		println('inputs: ${cfg.inputs}')
		println('includes: ${cfg.includes}')
		println('defines: ${cfg.defines}')
		println('disabled: ${cfg.disabled}')
		println('tasks: ${cfg.tasks.keys()}')
		println('plugins: ${cfg.plugins.keys()}')
		return 0
	}
	eprintln('usage: fcc config show')
	return 1
}

fn cmd_init(args []string, cfg core.FccConfig) int {
	use_blip := '--blip' in args
	if use_blip {
		os.write_file('fcc.blip', starter_blip()) or {
			eprintln('cannot write fcc.blip')
			return 1
		}
		os.write_file('build.blip', starter_build_blip()) or {
			eprintln('cannot write build.blip')
			return 1
		}
		println('wrote fcc.blip + build.blip')
		return 0
	}
	os.write_file('fcc.toml', starter_toml()) or {
		eprintln('cannot write fcc.toml')
		return 1
	}
	os.write_file('build.v', starter_build_v()) or {
		eprintln('cannot write build.v')
		return 1
	}
	println('wrote fcc.toml + build.v')
	return 0
}

fn starter_toml() string {
	return '# fcc project config (TOML). CLI flags override everything here.\n[build]\ntarget = "x86_64-windows"\nstd = "gnu11"\nemit = "asm"\ninputs = ["main.c"]\nincludes = []\ndefines = []\n\n[plugins]\ndisabled = []\n\n[task.build]\nrun = "fcc -S -o main.s main.c"\ndesc = "compile to assembly"\n'
}

fn starter_blip() string {
	return '# fcc project config (blip). Same keys as fcc.toml.\nbuild {\n  target = "x86_64-windows"\n  std = "gnu11"\n  emit = "asm"\n}\n'
}

fn starter_build_blip() string {
	return '# build.blip: declarative tasks (like build.zig steps).\ntask "build" {\n  inputs = ["main.c"]\n  run = "fcc -S -o main.s main.c"\n}\n'
}

fn starter_build_v() string {
	return '// build.v: programmatic build (like build.zig). Run with: fcc build\nmodule main\n\nimport os\n\nfn main() {\n\tprintln("build.v: compiling main.c")\n\tr := os.execute("fcc -S -o main.s main.c")\n\tprint(r.output)\n\texit(r.exit_code)\n}\n'
}
