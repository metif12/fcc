module core

import os

// CliCommand is one `fcc <name>` verb. In-process CLI plugins register
// commands; anything else dispatches to `fcc-<name>` on PATH.
pub struct CliCommand {
pub:
	name        string
	usage       string
	description string
	handler     fn (args []string, cfg FccConfig) int @[required]
}

__global cli_registry []CliCommand

pub fn register_command(cmd CliCommand) {
	for i, c in cli_registry {
		if c.name == cmd.name {
			cli_registry[i] = cmd
			return
		}
	}
	cli_registry << cmd
}

pub fn list_commands() []CliCommand {
	return cli_registry.clone()
}

pub fn find_command(name string) ?CliCommand {
	for c in cli_registry {
		if c.name == name {
			return c
		}
	}
	return none
}

pub fn reset_commands() {
	cli_registry = []CliCommand{}
}

// is_legacy_flag reports the historic `fcc [options] file...` shape so the
// default CLI plugin keeps working: anything starting with `-` or ending
// with a C-ish extension is a legacy compile invocation, not a verb.
pub fn is_legacy_flag(arg string) bool {
	if arg.starts_with('-') {
		return true
	}
	lower := arg.to_lower()
	return lower.ends_with('.c') || lower.ends_with('.h') || lower.ends_with('.o')
		|| lower.ends_with('.obj') || lower.ends_with('.a') || lower.ends_with('.lib')
		|| lower.ends_with('.s') || lower.ends_with('.toml') || lower.ends_with('.blip')
		|| lower.ends_with('.v')
}

// dispatch_verb runs `fcc <verb> ...`. Returns -1 when no handler matched
// (caller falls back to legacy compile), else the exit code.
//
// Precedence: an enabled in-process command first, then a config-declared
// `[plugin."verb"] command`, then `fcc-<verb>` on PATH (like git/cargo
// subcommands). A disabled in-process command is skipped, so config can
// replace a builtin verb with an external one of the same name.
pub fn dispatch_verb(args []string, cfg FccConfig) int {
	if args.len == 0 {
		return -1
	}
	first := args[0]
	if first.starts_with('-') || first.ends_with('.c') || first.ends_with('.h') {
		return -1
	}
	if cmd := find_command(first) {
		if !is_disabled(cmd.name) && !is_plugin_disabled(cmd.name, cfg) {
			return cmd.handler(args[1..], cfg)
		}
	}
	// Config-declared external command: `[plugin."verb"] command = "..."`.
	// `path` (an executable file) wins over `command` (a shell line) when
	// both are set; neither set means "not an external command".
	if def := cfg.plugins[first] {
		if def.enabled && !is_disabled(first) {
			if def.path != '' {
				// `path` names an executable file: run it directly with no
				// shell, so paths with spaces need no quoting and no
				// shell metacharacter in an argument can inject.
				mut cmd := [def.path]
				cmd << args[1..]
				r := os.exec(cmd)
				print(r.output)
				return r.exit_code
			}
			if def.command != '' {
				// `command` is a shell line (it may use builtins, pipes,
				// or extra flags, e.g. `command = "echo hi"`): it needs
				// a shell by definition, like build-task `run` lines.
				r := exec_shell('${def.command} ${args[1..].join(' ')}')
				print(r.output)
				return r.exit_code
			}
		}
	}
	// External plugin: fcc-<verb> on PATH (like git/cargo subcommands).
	ext := 'fcc-' + first
	if found := os.find_abs_path_of_executable(ext) {
		mut cmd := [found]
		cmd << args[1..]
		r := os.exec(cmd)
		print(r.output)
		return r.exit_code
	}
	return -1
}

pub fn cli_help() string {
	mut lines := ['usage: fcc [options] file... | fcc <command> [args]', '', 'commands:']
	for c in cli_registry {
		lines << '  ${c.name}  ${c.description}'
	}
	lines << ''
	lines << 'legacy compile flags: fcc --help (default-cli plugin)'
	lines << 'external plugins: place fcc-<verb> on PATH'
	return lines.join('\n')
}
