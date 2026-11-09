module core

// Pipeline runner: inputs -> hooks -> outputs. Driver builds the
// PipelineContext from CLI + config, then hands it here so the ordering
// lives in one place and plugins only implement stages.

pub fn run_pipeline(mut ctx PipelineContext, input_names []string) ! {
	run_hooks(.pre_parse, mut ctx)!
	// Load each input through its registered InputPlugin.
	for path in input_names {
		p := find_input(path) or { return error('no input plugin handles "${path}"') }
		p.load(path, mut ctx)!
	}
	ctx.inputs = input_names
	// Several inputs share one namespace for generated names; qualify past
	// the first unit before hooks or codegen see them.
	dedupe_generated_names(mut ctx)
	run_hooks(.post_parse, mut ctx)!
	run_hooks(.pre_codegen, mut ctx)!
	out := find_output(ctx.emit) or { return error('no output plugin for format "${ctx.emit}"') }
	out.emit(mut ctx)!
	run_hooks(.post_codegen, mut ctx)!
	run_hooks(.pre_link, mut ctx)!
	run_hooks(.post_build, mut ctx)!
}

// is_plugin_disabled consults cfg.disabled + [plugin."name"].enabled.
pub fn is_plugin_disabled(name string, cfg FccConfig) bool {
	if name in cfg.disabled {
		return true
	}
	if p := cfg.plugins[name] {
		return !p.enabled
	}
	return false
}
