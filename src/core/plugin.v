module core

import src.ast

// Plugin core: every part of fcc (inputs, outputs, hooks, CLI) is an
// extension behind a registry. The stock compiler ships as default
// extensions registered by `src/ext`; config can disable / override them.
//
// External (out-of-process) extensions are supported two ways:
//   1. CLI subcommands: `fcc <verb>` dispatches to `fcc-<verb>` on PATH
//      when no in-process command matches (see commands.v).
//   2. Input/output via external commands declared in fcc.toml / fcc.blip
//      ([[tool.input]] / [[tool.output]] with a `command = "..."`).

// Stage is a hook point in the compile pipeline.
pub enum Stage {
	pre_parse
	post_parse
	pre_codegen
	post_codegen
	pre_link
	post_build
	on_error
}

// PipelineContext is the shared state every plugin reads / writes.
// It intentionally mirrors only the data plugins need, not driver.Options,
// so core never imports driver (which would be a cycle).
pub struct PipelineContext {
pub mut:
	inputs       []string
	output       string
	target       string
	std          string
	includes     []string
	sys_includes []string
	defines      []string
	undefines    []string
	pre_includes []string
	emit         string // 'asm' | 'obj' | 'exe' | 'tokens' | 'preprocessed' | 'ast' | 'v'
	verbose      bool
	// parsed AST units, one entry per input that an InputPlugin loaded.
	globals [][]&ast.Obj
	// generated text units (asm / v / tokens), one per input.
	units []string
	// free-form bag hooks and outputs use to communicate.
	data        map[string]string
	diagnostics []string
	failed      bool
}

// InputPlugin loads one input file into the pipeline.
pub interface InputPlugin {
	name() string
	// extensions handled, e.g. ['.c', '.h']. Empty means "claim anything".
	extensions() []string
	can_handle(path string) bool
	// load returns opaque per-file state; default C plugin appends to ctx.
	load(path string, mut ctx PipelineContext) !
}

// OutputPlugin consumes the pipeline state and writes the result.
pub interface OutputPlugin {
	name() string
	// formats emitted, e.g. ['asm', 's']. The pipeline picks by ctx.emit.
	formats() []string
	emit(mut ctx PipelineContext) !
}

// HookPlugin runs at one pipeline stage.
pub interface HookPlugin {
	name() string
	stage() Stage
	// lower runs first.
	priority() int
	run(mut ctx PipelineContext) !
}

// CLI registration is in commands.v; plugin.v only owns input/output/hook
// registries so commands.v can stay small.

__global input_registry []InputPlugin
__global output_registry []OutputPlugin
__global hook_registry []HookPlugin
// disabled_names is the effective disable set from the loaded config
// (`[plugins] disabled` plus `[plugin.*] enabled = false`), installed by
// `apply_config`. Registries are process-global, so the disable set is too:
// `find_input`/`find_output`/`run_hooks` consult it, which is what makes a
// disabled plugin actually absent from the pipeline rather than merely
// labelled in `fcc plugin list`.
__global disabled_names []string

// apply_config installs the config's disable set for this process. The driver
// calls it once, right after loading the effective config and registering
// defaults; tests call it (or `reset_registries`, which clears it) per case.
pub fn apply_config(cfg FccConfig) {
	mut names := []string{}
	for n in cfg.disabled {
		if n !in names {
			names << n
		}
	}
	for name, def in cfg.plugins {
		if !def.enabled && name !in names {
			names << name
		}
	}
	disabled_names = names.clone()
}

pub fn is_disabled(name string) bool {
	return name in disabled_names
}

// input_claimed_by_disabled reports an input only a disabled plugin claims.
// The driver uses it to fail with "enable it" instead of misparsing the file
// as C on the legacy path.
pub fn input_claimed_by_disabled(path string) bool {
	lower := path.to_lower()
	for p in input_registry {
		if !is_disabled(p.name()) {
			continue
		}
		exts := p.extensions()
		if exts.len == 0 && p.can_handle(path) {
			return true
		}
		for e in exts {
			if lower.ends_with(e.to_lower()) && p.can_handle(path) {
				return true
			}
		}
	}
	return false
}

pub fn register_input(p InputPlugin) {
	input_registry << p
}

pub fn register_output(p OutputPlugin) {
	output_registry << p
}

pub fn register_hook(p HookPlugin) {
	hook_registry << p
}

pub fn list_inputs() []InputPlugin {
	return input_registry.clone()
}

pub fn list_outputs() []OutputPlugin {
	return output_registry.clone()
}

pub fn list_hooks() []HookPlugin {
	return hook_registry.clone()
}

pub fn find_input(path string) ?InputPlugin {
	lower := path.to_lower()
	for p in input_registry {
		if is_disabled(p.name()) {
			continue
		}
		exts := p.extensions()
		if exts.len == 0 && p.can_handle(path) {
			return p
		}
		for e in exts {
			if lower.ends_with(e.to_lower()) && p.can_handle(path) {
				return p
			}
		}
	}
	return none
}

pub fn find_output(format string) ?OutputPlugin {
	for p in output_registry {
		if is_disabled(p.name()) {
			continue
		}
		if format in p.formats() {
			return p
		}
	}
	return none
}

pub fn run_hooks(stage Stage, mut ctx PipelineContext) ! {
	mut hs := hook_registry.filter(it.stage() == stage && !is_disabled(it.name()))
	hs.sort(a.priority() < b.priority())
	for h in hs {
		h.run(mut ctx)!
	}
}

// reset_registries clears all registrations. Tests only.
pub fn reset_registries() {
	input_registry = []InputPlugin{}
	output_registry = []OutputPlugin{}
	hook_registry = []HookPlugin{}
	disabled_names = []string{}
}
