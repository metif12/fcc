module ext

import os
import src.core
import src.fcc

// Second half of default outputs: preprocessed / ast-dump / exe-link.
// Kept separate so each output plugin reads as one unit.

pub struct PreprocessedOutput {
pub:
	plugin_name string = 'default-preprocessed-output'
}

pub fn (p PreprocessedOutput) name() string {
	return p.plugin_name
}

pub fn (p PreprocessedOutput) formats() []string {
	return ['preprocessed', 'E', 'i']
}

pub fn (p PreprocessedOutput) emit(mut ctx core.PipelineContext) ! {
	mut lines := ['--- preprocessed']
	for path in ctx.inputs {
		mut pp := fcc.preprocessor(ctx.includes, ctx.sys_includes)
		for spec in ctx.defines {
			pp.define_from_option(spec)
		}
		for n in ctx.undefines {
			pp.undefine(n)
		}
		pp.define_builtins()
		pre := pp.run(path)
		for e in pre.errors {
			ctx.diagnostics << e
		}
		lines << '--- ${path}'
		for t in pre.tokens {
			if t.kind == .eof {
				continue
			}
			lines << '${t.line.disp_line}: ${t.kind} "${t.text}"'
		}
	}
	text := lines.join('\n')
	ctx.units = [text]
	if ctx.output == '' {
		println(text)
	} else {
		os.write_file(ctx.output, text) or { return error('cannot write ${ctx.output}') }
	}
}

pub struct AstDumpOutput {
pub:
	plugin_name string = 'default-ast-output'
}

pub fn (p AstDumpOutput) name() string {
	return p.plugin_name
}

pub fn (p AstDumpOutput) formats() []string {
	return ['ast']
}

pub fn (p AstDumpOutput) emit(mut ctx core.PipelineContext) ! {
	// Dump what the input plugins loaded, not a fresh parse: re-reading the
	// file here would bypass every non-C input plugin (their paths are not
	// C source). For C inputs the globals are identical either way.
	mut lines := []string{}
	for i, path in ctx.inputs {
		lines << '--- ${path}'
		if i < ctx.globals.len {
			parsed := fcc.ParseResult{
				globals: ctx.globals[i]
			}
			lines << parsed.dump()
		}
	}
	text := lines.join('\n')
	ctx.units = [text]
	if ctx.output == '' {
		print(text)
	} else {
		os.write_file(ctx.output, text) or { return error('cannot write ${ctx.output}') }
	}
}

pub struct ExeOutput {
pub:
	plugin_name string = 'default-exe-output'
}

pub fn (p ExeOutput) name() string {
	return p.plugin_name
}

pub fn (p ExeOutput) formats() []string {
	return ['exe']
}

pub fn (p ExeOutput) emit(mut ctx core.PipelineContext) ! {
	// Phase 1 shape: front end runs, codegen via AsmOutput path, link via cc.
	// Full link is driver-owned; this default refuses rather than silently
	// producing a half binary, and driver maps it to its legacy message.
	return error('phase 1: front end runs, no code is generated yet (use --emit asm/obj)')
}

pub fn register_extra_outputs() {
	core.register_output(PreprocessedOutput{})
	core.register_output(AstDumpOutput{})
	core.register_output(ExeOutput{})
}
