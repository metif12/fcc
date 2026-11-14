module ext

import os
import src.core
import src.fcc

// Installable external plugins, declared in config instead of compiled in.
//
// An in-process plugin (Brainfuck, Bash, the defaults) is a struct behind a
// registry interface. An *external* plugin is a command the config names:
//
// ```toml
// [plugin."wlang"]
// command = "wlang-transpile"
// extensions = [".w"]
// ```
//
// `register_external_inputs` turns each such declaration into an `InputPlugin`
// that runs the command and feeds its stdout through the C front end — the
// same transpile-and-reuse shape as the in-process language plugins, except
// the transpiler is any executable, in any language. CLI verbs work the same
// way without registration: `[plugin."greet"] command = "greet --hi"` makes
// `fcc greet ...` run it (see `core.dispatch_verb`).
//
// Discovery has three layers, in order: in-process registry, config-declared
// commands, `fcc-<verb>` executables on PATH. `fcc plugin list` shows all
// three; `fcc plugin add/remove` edits the config declarations.

// ExternalInput runs a config-declared transpiler command for its extensions.
//
// The command is invoked as `<command> <path>` and must print a C translation
// unit on stdout; a nonzero exit or an empty stdout is a load error naming the
// plugin. Anything the transpiler prints on stderr passes through untouched,
// so diagnostics keep working without a protocol.
pub struct ExternalInput {
pub:
	plugin_name string
	command     string
	exts        []string
}

pub fn (p ExternalInput) name() string {
	return p.plugin_name
}

pub fn (p ExternalInput) extensions() []string {
	return p.exts.clone()
}

pub fn (p ExternalInput) can_handle(path string) bool {
	l := path.to_lower()
	for e in p.exts {
		if l.ends_with(e.to_lower()) {
			return true
		}
	}
	return false
}

pub fn (p ExternalInput) load(path string, mut ctx core.PipelineContext) ! {
	mut parts := p.command.split(' ')
	parts << path
	r := os.exec(parts)
	if r.exit_code != 0 {
		ctx.diagnostics << '${p.plugin_name}: command exited ${r.exit_code}: ${r.output}'
		ctx.failed = true
		return error('external input ${p.plugin_name} failed for ${path}')
	}
	generated := r.output
	if generated.trim_space() == '' {
		ctx.diagnostics << '${p.plugin_name}: command produced no output for ${path}'
		ctx.failed = true
		return error('external input ${p.plugin_name} produced no output for ${path}')
	}
	// Same front end as CFileInput, fed from generated text (like bf/bf).
	mut pp := fcc.preprocessor(ctx.includes, ctx.sys_includes)
	for spec in ctx.defines {
		pp.define_from_option(spec)
	}
	for n in ctx.undefines {
		pp.undefine(n)
	}
	pp.define_builtins()
	pre := pp.run_text(generated, path)
	for e in pre.errors {
		ctx.diagnostics << '${path}: ${e}'
		ctx.failed = true
	}
	parsed := fcc.parse_tokens(pre.tokens, path, pp.packs)
	for e in parsed.errors {
		ctx.diagnostics << e
		ctx.failed = true
	}
	for w in parsed.warnings {
		ctx.diagnostics << w
	}
	if parsed.errors.len > 0 {
		return error('parse failed for ${path}')
	}
	ctx.globals << parsed.globals
}

// external_plugin_name prefixes config-declared inputs so they never collide
// with in-process names and `fcc plugin list` shows where each came from.
pub fn external_plugin_name(key string) string {
	return 'external-' + key
}

// register_external_inputs registers one ExternalInput per config-declared
// input plugin: enabled, with a command and at least one extension. The kind
// defaults to input when extensions are present; an explicit `kind` wins.
// Re-running is safe: names already registered are skipped, so the driver can
// call this on every invocation without growing the registry.
pub fn register_external_inputs(cfg core.FccConfig) {
	for key, def in cfg.plugins {
		if !def.enabled {
			continue
		}
		if def.command == '' && def.path == '' {
			continue
		}
		kind := if def.kind != '' {
			def.kind
		} else if def.extensions.len > 0 {
			'input'
		} else if def.formats.len > 0 {
			'output'
		} else {
			'cli'
		}
		if kind != 'input' {
			continue
		}
		if def.extensions.len == 0 {
			continue
		}
		cmd := if def.path != '' { def.path } else { def.command }
		name := external_plugin_name(key)
		mut present := false
		for p in core.list_inputs() {
			if p.name() == name {
				present = true
				break
			}
		}
		if present {
			continue
		}
		core.register_input(ExternalInput{
			plugin_name: name
			command:     cmd
			exts:        def.extensions.clone()
		})
	}
}

// discover_external_commands scans PATH for `fcc-*` executables, the
// zero-config discovery layer (like git/cargo subcommands).
pub fn discover_external_commands() []string {
	path_env := os.getenv('PATH')
	if path_env == '' {
		return []string{}
	}
	mut found := []string{}
	sep := $if windows { ';' } $else { ':' }
	suffix := $if windows { '.exe' } $else { '' }
	for dir in path_env.split(sep) {
		if dir == '' || !os.is_dir(dir) {
			continue
		}
		entries := os.ls(dir) or { continue }
		for e in entries {
			name := if suffix != '' && e.to_lower().ends_with(suffix) {
				e[..e.len - suffix.len]
			} else {
				e
			}
			if name.starts_with('fcc-') && name.len > 4 && name !in found {
				verb := name[4..]
				// The name on PATH is the whole contract; arguments pass through.
				found << verb
			}
		}
	}
	found.sort()
	return found
}

// plugin_add_to_file installs (or updates) a `[plugin."name"]` declaration in
// the config file at path, creating the file when missing. Keys written:
// command/path, kind, extensions, formats. It edits text, not a TOML tree,
// so comments and unrelated sections survive byte-identical.
pub fn plugin_add_to_file(path string, name string, def core.PluginDef) ! {
	mut text := ''
	if os.is_file(path) {
		text = os.read_file(path)!
	}
	header := '[plugin."' + name + '"]'
	mut lines := if text == '' { []string{} } else { text.split('\n') }
	// Drop any existing section for this plugin.
	mut kept := []string{}
	mut i := 0
	for i < lines.len {
		if lines[i].trim_space() == header {
			i++
			for i < lines.len {
				t := lines[i].trim_space()
				if t.starts_with('[') && t.ends_with(']') {
					break
				}
				i++
			}
			continue
		}
		kept << lines[i]
		i++
	}
	// Trim trailing blank lines before appending, then separate with one.
	for kept.len > 0 && kept[kept.len - 1].trim_space() == '' {
		kept.pop()
	}
	if kept.len > 0 {
		kept << ''
	}
	kept << header
	if def.command != '' {
		kept << 'command = "${toml_escape(def.command)}"'
	}
	if def.path != '' {
		kept << 'path = "${toml_escape(def.path)}"'
	}
	if def.kind != '' {
		kept << 'kind = "${def.kind}"'
	}
	if def.extensions.len > 0 {
		kept << 'extensions = [${quote_list(def.extensions)}]'
	}
	if def.formats.len > 0 {
		kept << 'formats = [${quote_list(def.formats)}]'
	}
	if def.enabled == false {
		kept << 'enabled = false'
	}
	kept << ''
	os.write_file(path, kept.join('\n'))!
}

// toml_escape escapes a value for a TOML basic string: backslashes (Windows
// paths) and quotes. Without it `C:\new` parses as an escape sequence.
fn toml_escape(s string) string {
	mut r := ''
	for c in s {
		match c {
			92 { r += '\\\\' }
			34 { r += '\\"' }
			else { r += c.ascii_str() }
		}
	}
	return r
}

fn quote_list(items []string) string {
	mut out := []string{}
	for s in items {
		out << '"${s}"'
	}
	return out.join(', ')
}

// plugin_remove_from_file uninstalls the `[plugin."name"]` declaration,
// leaving everything else byte-identical. Missing file or section is not an
// error.
pub fn plugin_remove_from_file(path string, name string) ! {
	if !os.is_file(path) {
		return
	}
	text := os.read_file(path)!
	header := '[plugin."' + name + '"]'
	lines := text.split('\n')
	mut kept := []string{}
	mut i := 0
	for i < lines.len {
		if lines[i].trim_space() == header {
			i++
			for i < lines.len {
				t := lines[i].trim_space()
				if t.starts_with('[') && t.ends_with(']') {
					break
				}
				i++
			}
			continue
		}
		kept << lines[i]
		i++
	}
	// Collapse runs of blank lines left by the removal, keeping one at most.
	mut clean := []string{}
	for l in kept {
		if l.trim_space() == '' && clean.len > 0 && clean[clean.len - 1].trim_space() == '' {
			continue
		}
		clean << l
	}
	os.write_file(path, clean.join('\n'))!
}
