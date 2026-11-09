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
		name:        'run'
		usage:       'fcc run [-I dir] [-D def] [-B root] file... [-- prog args...]'
		description: 'compile inputs to a temp binary and run it (go run style)'
		handler:     cmd_run
	})
	core.register_command(core.CliCommand{
		name:        'test'
		usage:       'fcc test [dir|file...] [-v]'
		description: 'run the test task, or compile and run *_test.c files'
		handler:     cmd_test
	})
	core.register_command(core.CliCommand{
		name:        'watch'
		usage:       'fcc watch [--clear] [--debounce ms] [command...]'
		description: 're-run a command when watched files change (air style)'
		handler:     cmd_watch
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
	if '--help' in args || '-h' in args {
		println('usage: fcc build [task...] [--force|-f]')
		println('tasks:')
		mut names := cfg.tasks.keys()
		names.sort()
		for name in names {
			t := cfg.tasks[name]
			desc := if t.desc != '' { '  ' + t.desc } else { '' }
			println('  ${name}${desc}')
		}
		return 0
	}
	force := '--force' in args || '-f' in args
	targets := args.filter(!it.starts_with('-'))
	core.run_tasks_forced(cfg.tasks, targets, fn (run string) int {
		if run == '' {
			return 0
		}
		r := os.execute(run)
		print(r.output)
		return r.exit_code
	}, force) or {
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
		println('config-declared:')
		if cfg.plugins.len == 0 {
			println('  (none — fcc plugin add <name> -- <command> [--ext .foo])')
		}
		for name, def in cfg.plugins {
			disabled := if !def.enabled { ' [disabled]' } else { '' }
			println('  ${name}${disabled}  kind=${def.kind} command=${def.command} ext=${def.extensions}')
		}
		println('on PATH:')
		found := discover_external_commands()
		if found.len == 0 {
			println('  (none — any fcc-<verb> on PATH is also a command)')
		}
		for verb in found {
			println('  ${verb}')
		}
		return 0
	}
	if args.len >= 2 && args[0] == 'add' {
		return cmd_plugin_add(args[1..])
	}
	if args.len == 2 && args[0] == 'remove' {
		plugin_remove_from_file('fcc.toml', args[1]) or {
			eprintln('fcc plugin remove: ${err.msg()}')
			return 1
		}
		println('removed ${args[1]} from fcc.toml')
		return 0
	}
	eprintln('usage: fcc plugin list')
	eprintln('       fcc plugin add <name> -- <command...> [--ext .foo[,.bar]] [--kind input|cli] [--path <exe>]')
	eprintln('       fcc plugin remove <name>')
	return 1
}

// cmd_plugin_add implements `fcc plugin add`: install an external plugin
// declaration into fcc.toml. Everything after `--` is the command; `--ext`
// claims extensions (implying kind=input), `--kind` overrides the inference,
// `--path` records an executable instead of a shell line.
fn cmd_plugin_add(args []string) int {
	if args.len == 0 {
		eprintln('usage: fcc plugin add <name> -- <command...> [--ext .foo[,.bar]] [--kind input|cli]')
		return 1
	}
	name := args[0]
	mut rest := args[1..].clone()
	mut exts := []string{}
	mut kind := ''
	mut path := ''
	mut cmd_parts := []string{}
	mut i := 0
	for i < rest.len {
		a := rest[i]
		if a == '--ext' && i + 1 < rest.len {
			for e in rest[i + 1].split(',') {
				e2 := e.trim_space()
				if e2 != '' {
					exts << e2
				}
			}
			i += 2
			continue
		}
		if a == '--kind' && i + 1 < rest.len {
			kind = rest[i + 1]
			i += 2
			continue
		}
		if a == '--path' && i + 1 < rest.len {
			path = rest[i + 1]
			i += 2
			continue
		}
		if a == '--' {
			i++
			continue
		}
		cmd_parts << a
		i++
	}
	command := cmd_parts.join(' ')
	if command == '' && path == '' {
		eprintln('fcc plugin add: need a command (after --) or --path <exe>')
		return 1
	}
	if kind == '' {
		kind = if exts.len > 0 { 'input' } else { 'cli' }
	}
	plugin_add_to_file('fcc.toml', name, core.PluginDef{
		command:    command
		path:       path
		kind:       kind
		extensions: exts
	}) or {
		eprintln('fcc plugin add: ${err.msg()}')
		return 1
	}
	println('added ${name} to fcc.toml')
	return 0
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
