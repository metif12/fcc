module driver

import os
import src.core

// Multiple outputs, one invocation.
//
// Today each flag owns the whole run (`-S` *or* `-c`): asking for assembly
// *and* an object means compiling twice. `--emit` (repeatable) and
// `[output."<fmt>"]` (config) instead describe a *list* of outputs, and the
// driver runs each in turn — legacy or pipeline, per input kinds — sharing
// nothing but the parsed flags. `--emit asm=x.s --emit obj=x.o main.c`
// is `fcc -S -o x.s main.c` followed by `fcc -c -o x.o main.c`, in one
// process, parsed once.
//
// Precedence per output is explicit: `=<path>` wins, then the config
// `[output."<fmt>"] path`, then `-o` (single output only), then the
// main-stem default (`main.c` -> `main.s`). With no `--emit` and no
// `[output.*]`, the legacy single-mode path runs bit-for-bit as before.

// OutputReq is one requested output: a canonical format and its path.
pub struct OutputReq {
pub mut:
	format string
	path   string
}

// canonical_emit_format maps a user spelling to a canonical format name.
pub fn canonical_emit_format(raw string) !string {
	return match raw.to_lower() {
		'asm', 's' { 'asm' }
		'obj', 'o' { 'obj' }
		'tokens' { 'tokens' }
		'preprocessed', 'e', 'i' { 'preprocessed' }
		'ast' { 'ast' }
		'v', 'to-v' { 'v' }
		'v-bindings' { 'v-bindings' }
		'exe' {
			return error('--emit exe is not supported (link objects with gcc: fcc -c ... && gcc ...)')
		}
		else {
			return error('unknown emit format "${raw}" (want asm, obj, tokens, preprocessed, ast, v, v-bindings)')
		}
	}
}

// default_ext_for is the filename extension a stem-built path gets.
pub fn default_ext_for(format string) string {
	return match format {
		'asm' { '.s' }
		'obj' { '.o' }
		'tokens' { '.txt' }
		'preprocessed' { '.i' }
		'ast' { '.ast' }
		'v' { '.v' }
		'v-bindings' { '.bindings.v' }
		else { '.out' }
	}
}

// stem_for is the basename outputs default from: the first input without
// its extension, or `out` with no inputs.
pub fn stem_for(inputs []string) string {
	if inputs.len == 0 {
		return 'out'
	}
	base := os.file_name(inputs[0])
	if idx := base.last_index('.') {
		if idx > 0 {
			return base[..idx]
		}
	}
	return base
}

// resolve_outputs merges CLI `--emit` (in flag order, first mention wins)
// with config `[output.*]` (formats the CLI did not claim, sorted).
// Empty means "no multi-output requested": the caller runs the legacy
// single-mode dispatch untouched.
pub fn resolve_outputs(o &Options, cfg &core.FccConfig) ![]OutputReq {
	if o.emits.len > 0
		&& (o.emit_asm || o.compile_only || o.dump_tokens || o.preprocess_only || o.dump_ast || o.emit_v || o.emit_v_bindings) {
		return error('cannot combine -S/-c/-E/--dump-tokens/--dump-ast/--to-v with --emit (express every output as --emit <fmt>[=<path>])')
	}
	mut reqs := []OutputReq{}
	mut seen := map[string]bool{}
	for raw in o.emits {
		mut fmt := raw
		mut path := ''
		if idx := raw.index('=') {
			if idx == 0 {
				return error('bad --emit "${raw}": empty format')
			}
			fmt = raw[..idx]
			path = raw[idx + 1..]
		}
		c := canonical_emit_format(fmt)!
		if c in seen {
			continue
		}
		seen[c] = true
		if path == '' {
			if d := cfg.outputs[c] {
				path = d.path
			}
		}
		reqs << OutputReq{
			format: c
			path:   path
		}
	}
	mut keys := cfg.outputs.keys()
	keys.sort()
	for k in keys {
		c := canonical_emit_format(k) or {
			return error('unknown output format in [output."${k}"] (want asm, obj, tokens, preprocessed, ast, v, v-bindings)')
		}
		if c in seen {
			continue
		}
		seen[c] = true
		reqs << OutputReq{
			format: c
			path:   cfg.outputs[k].path
		}
	}
	if reqs.len == 1 && reqs[0].path == '' {
		// One output, no path anywhere: exactly today's behavior — `-o`
		// (or stdout / the legacy default) owns it.
		reqs[0].path = o.output
		return reqs
	}
	for i in 0 .. reqs.len {
		if reqs[i].path == '' {
			reqs[i].path = stem_for(o.inputs) + default_ext_for(reqs[i].format)
		}
	}
	return reqs
}

// run_multi_output produces every requested output in order. Each entry runs
// the same single-output dispatch (legacy or pipeline, per input kinds), so
// a mixed-language unit set links the same way whatever else is emitted
// alongside it.
fn run_multi_output(o &Options, cfg &core.FccConfig, reqs []OutputReq) {
	if reqs.len > 1 && o.output != '' {
		eprintln('fcc: -o ignored with multiple --emit outputs (give each its own =path or [output.<fmt>] path)')
	}
	for r in reqs {
		mut oo := *o
		oo.output = r.path
		oo.emit_asm = false
		oo.compile_only = false
		oo.dump_tokens = false
		oo.preprocess_only = false
		oo.dump_ast = false
		oo.emit_v = false
		oo.emit_v_bindings = false
		match r.format {
			'asm' {
				oo.emit_asm = true
			}
			'obj' {
				oo.compile_only = true
			}
			'tokens' {
				oo.dump_tokens = true
			}
			'preprocessed' {
				oo.preprocess_only = true
			}
			'ast' {
				oo.dump_ast = true
			}
			'v' {
				oo.emit_v = true
			}
			'v-bindings' {
				oo.emit_v_bindings = true
			}
			else {}
		}
		run_single_output(&oo, cfg)
	}
}

// run_single_output is the legacy one-output dispatch: raw-text modes stay
// legacy, plugin-claimed inputs divert to the pipeline, everything else runs
// the legacy C path. Multi-output runs this once per entry, so one output
// behaves exactly as the equivalent flag did before `--emit` existed.
fn run_single_output(o &Options, cfg &core.FccConfig) {
	if o.dump_tokens {
		dump_tokens(o)
		return
	}
	if o.preprocess_only {
		dump_preprocessed(o)
		return
	}
	// Inputs a non-default input plugin claims (.bf today) go through the
	// plugin pipeline instead of the legacy C path, so third-party and
	// example languages compose with every output (-S, -c, link) that has
	// an output plugin. Raw-text modes above stay legacy: they work on
	// file bytes, not loaded inputs. --to-v below stays legacy too: it has
	// no output plugin.
	emit := pipeline_emit_for(o)
	if emit != '' && any_input_claimed_by_plugin(o, cfg) {
		run_pipeline_modes(o, emit)
		return
	}
	if emit != '' {
		for path in o.inputs {
			if core.input_claimed_by_disabled(path) {
				eprintln('fcc: ${path} needs a disabled plugin (enable it in fcc.toml or remove the [plugins] disabled entry)')
				exit(1)
			}
		}
	}
	if o.dump_ast {
		dump_ast(o)
		return
	}
	if o.emit_v {
		emit_v(o)
		return
	}
	if o.emit_v_bindings {
		emit_v_bindings(o)
		return
	}
	if o.emit_asm {
		emit_asm(o)
		return
	}
	if o.compile_only {
		emit_obj(o)
		return
	}
	eprintln('fcc: phase 1 — the front end runs, but no code is generated yet')
	exit(1)
}
