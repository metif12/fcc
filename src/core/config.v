module core

import os
import toml

// FccConfig is the file-backed configuration. Every field has a CLI
// override; CLI wins over file, file wins over builtins.
// Sources: fcc.toml, fcc.blip, .fcc.toml, .fcc.blip (first hit wins),
// plus --config <path> for an explicit file.

pub struct TaskDef {
pub mut:
	inputs  []string
	run     string
	depends []string
	desc    string
}

pub struct PluginDef {
pub mut:
	enabled bool = true
	path    string
	command string
	options map[string]string
}

pub struct FccConfig {
pub mut:
	// [build]
	target       string
	std          string
	output       string
	includes     []string
	sys_includes []string
	defines      []string
	undefines    []string
	pre_includes []string
	lib_paths    []string
	libs         []string
	emit         string
	verbose      bool
	// raw inputs listed in config (merged with CLI inputs).
	inputs []string
	// [plugin."name"] + [plugins] enable/disable table.
	plugins map[string]PluginDef
	// disabled lists plugin names to skip even if registered.
	disabled []string
	// [task."name"]
	tasks map[string]TaskDef
	// which file it came from, for diagnostics.
	source string
}

pub fn default_config() FccConfig {
	return FccConfig{
		std:  'gnu11'
		emit: 'exe'
	}
}

// merge_build_tasks loads build.blip / build.toml tasks from dir into cfg.
// fcc.toml [task.*] and build.* tasks merge; build.* wins on name clash.
// build.v is programmatic and handled by delegate_build_v, not here.
pub fn (mut cfg FccConfig) merge_build_tasks(dir string) {
	for name in ['build.blip', 'build.toml'] {
		p := os.join_path(dir, name)
		if os.is_file(p) {
			bc := load_config_file(p) or { return }
			for k, v in bc.tasks {
				cfg.tasks[k] = v
			}
			if cfg.source == '' {
				cfg.source = p
			}
			return
		}
	}
}

// discover_config finds the config file for dir (or cwd).
// Order: --config override handled by caller; here:
// fcc.toml, fcc.blip, .fcc.toml, .fcc.blip
pub fn discover_config(dir string) string {
	for name in ['fcc.toml', 'fcc.blip', '.fcc.toml', '.fcc.blip'] {
		p := os.join_path(dir, name)
		if os.is_file(p) {
			return p
		}
	}
	return ''
}

pub fn load_config_file(path string) !FccConfig {
	text := os.read_file(path)!
	return parse_config_text(text, path)!
}

pub fn parse_config_text(text string, source string) !FccConfig {
	toml_text := if source.to_lower().ends_with('.blip') { desugar_blip(text) } else { text }
	if toml_text.trim_space() == '' {
		mut c := default_config()
		c.source = source
		return c
	}
	doc := toml.parse_text(toml_text)!
	mut c := default_config()
	c.source = source
	c.target = doc_string(doc, 'build.target', '')
	// top-level `target` fallback (blip bare keys)
	if c.target == '' {
		c.target = doc_string(doc, 'target', '')
	}
	c.std = doc_string_or(doc, 'build.std', doc_string(doc, 'std', 'gnu11'))
	c.output = doc_string(doc, 'build.output', doc_string(doc, 'output', ''))
	c.emit = doc_string_or(doc, 'build.emit', doc_string(doc, 'emit', 'exe'))
	c.inputs = doc_str_array(doc, 'build.inputs', doc_str_array(doc, 'inputs', []string{}))
	c.includes = doc_str_array(doc, 'build.includes', doc_str_array(doc, 'includes', []string{}))
	c.sys_includes = doc_str_array(doc, 'build.sys_includes', doc_str_array(doc, 'sys_includes', []string{}))
	c.defines = doc_str_array(doc, 'build.defines', doc_str_array(doc, 'defines', []string{}))
	c.undefines = doc_str_array(doc, 'build.undefines', doc_str_array(doc, 'undefines', []string{}))
	c.pre_includes = doc_str_array(doc, 'build.pre_includes', doc_str_array(doc, 'pre_includes', []string{}))
	c.lib_paths = doc_str_array(doc, 'build.lib_paths', doc_str_array(doc, 'lib_paths', []string{}))
	c.libs = doc_str_array(doc, 'build.libs', doc_str_array(doc, 'libs', []string{}))
	c.verbose = doc_bool(doc, 'build.verbose', doc_bool(doc, 'verbose', false))
	c.disabled = doc_str_array(doc, 'plugins.disabled', doc_str_array(doc, 'disabled', []string{}))
	// tasks: [task."name"] with inputs/run/depends/desc
	tnames := doc_sub_tables(doc, 'task')
	for tname in tnames {
		base := 'task.' + dotted(tname)
		c.tasks[tname] = TaskDef{
			inputs:  doc_str_array(doc, base + '.inputs', []string{})
			run:     doc_string(doc, base + '.run', doc_string(doc, base + '.command', ''))
			depends: doc_str_array(doc, base + '.depends', []string{})
			desc:    doc_string(doc, base + '.desc', '')
		}
	}
	// plugins: [plugin."name"] with enabled/path/command
	pnames := doc_sub_tables(doc, 'plugin')
	for pname in pnames {
		base := 'plugin.' + dotted(pname)
		c.plugins[pname] = PluginDef{
			enabled: doc_bool(doc, base + '.enabled', true)
			path:    doc_string(doc, base + '.path', '')
			command: doc_string(doc, base + '.command', '')
		}
	}
	return c
}

fn dotted(name string) string {
	if name.contains(' ') || name.contains('-') || name.contains('.') {
		return '"' + name + '"'
	}
	return name
}

// --- tiny toml.Doc accessors (stringly, no reflection) ---

fn doc_string(doc toml.Doc, key string, def string) string {
	v := doc.value_opt(key) or { return def }
	return any_to_string(v, def)
}

fn doc_string_or(doc toml.Doc, a string, b string) string {
	if b != '' && b != 'exe' && b != 'gnu11' {
		return b
	}
	v := doc.value_opt(a) or { return b }
	return any_to_string(v, b)
}

fn doc_bool(doc toml.Doc, key string, def bool) bool {
	v := doc.value_opt(key) or { return def }
	match v {
		bool { return v }
		string { return v.to_lower() == 'true' || v == '1' }
		else { return def }
	}
}

fn doc_str_array(doc toml.Doc, key string, def []string) []string {
	v := doc.value_opt(key) or { return def }
	match v {
		[]toml.Any {
			mut out := []string{}
			for x in v {
				out << any_to_string(x, '')
			}
			return out
		}
		else {
			s := any_to_string(v, '')
			if s == '' {
				return def
			}
			return [s]
		}
	}
}

// doc_sub_tables lists direct children of a table, e.g. key 'task'
// -> ['build', 'test']. Uses the typed Any map, not string parsing.
fn doc_sub_tables(doc toml.Doc, key string) []string {
	v := doc.value_opt(key) or { return []string{} }
	match v {
		map[string]toml.Any {
			return v.keys()
		}
		else {
			return []string{}
		}
	}
}

fn any_to_string(v toml.Any, def string) string {
	match v {
		string { return v }
		bool { return if v { 'true' } else { 'false' } }
		i64 { return v.str() }
		f64 { return v.str() }
		else { return def }
	}
}
