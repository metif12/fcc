module ext

// Default extensions: the stock compiler re-expressed as plugins.
// Disabling any of these in fcc.toml ([plugin."default-..."] enabled=false)
// removes that capability; a third-party plugin with the same formats /
// extensions takes its place.

import os
import src.ast
import src.backend
import src.coff
import src.core
import src.fcc
import src.masm

// ---------- inputs ----------

pub struct CFileInput {
pub:
	plugin_name string = 'default-c-input'
}

pub fn (p CFileInput) name() string {
	return p.plugin_name
}

pub fn (p CFileInput) extensions() []string {
	return ['.c', '.h']
}

pub fn (p CFileInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.c') || l.ends_with('.h')
}

pub fn (p CFileInput) load(path string, mut ctx core.PipelineContext) ! {
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

// RawTextInput claims .s/.asm/.txt passthrough for future assemblers.
pub struct RawTextInput {
pub:
	plugin_name string = 'default-raw-input'
}

pub fn (p RawTextInput) name() string {
	return p.plugin_name
}

pub fn (p RawTextInput) extensions() []string {
	return ['.s', '.asm']
}

pub fn (p RawTextInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.s') || l.ends_with('.asm')
}

pub fn (p RawTextInput) load(path string, mut ctx core.PipelineContext) ! {
	text := os.read_file(path) or { return error('cannot read ${path}') }
	ctx.units << text
	ctx.globals << []&ast.Obj{}
}

// ---------- outputs ----------

fn gen_all(mut ctx core.PipelineContext) ![]string {
	if ctx.failed {
		return error(ctx.diagnostics.join('\n'))
	}
	mut out := []string{}
	for mut globals in ctx.globals {
		mut g := backend.AsmGen{}
		unit, errs := g.gen(mut globals)
		for e in errs {
			ctx.diagnostics << e
		}
		if errs.len > 0 {
			ctx.failed = true
			return error(errs.join('\n'))
		}
		out << unit
	}
	return out
}

pub struct AsmOutput {
pub:
	plugin_name string = 'default-asm-output'
}

pub fn (p AsmOutput) name() string {
	return p.plugin_name
}

pub fn (p AsmOutput) formats() []string {
	return ['asm', 's', 'S']
}

pub fn (p AsmOutput) emit(mut ctx core.PipelineContext) ! {
	out := gen_all(mut ctx)!
	text := out.join('\n')
	ctx.units = out
	if ctx.output == '' {
		print(text)
		return
	}
	os.write_file(ctx.output, text) or { return error('cannot write ${ctx.output}') }
}

pub struct ObjOutput {
pub:
	plugin_name string = 'default-obj-output'
}

pub fn (p ObjOutput) name() string {
	return p.plugin_name
}

pub fn (p ObjOutput) formats() []string {
	return ['obj', 'o']
}

pub fn (p ObjOutput) emit(mut ctx core.PipelineContext) ! {
	out := gen_all(mut ctx)!
	ctx.units = out
	text := out.join('\n')
	// Phase 3: assemble natively. The plugin path has no --extern-as escape
	// hatch; use `fcc -c` for that.
	native := masm.assemble(text) or { return error('assemble: ${err.msg()}') }
	coff.write_object(native, ctx.output) or { return error('${err.msg()}') }
}

pub struct TokensOutput {
pub:
	plugin_name string = 'default-tokens-output'
}

pub fn (p TokensOutput) name() string {
	return p.plugin_name
}

pub fn (p TokensOutput) formats() []string {
	return ['tokens']
}

pub fn (p TokensOutput) emit(mut ctx core.PipelineContext) ! {
	mut lines := []string{}
	for path in ctx.inputs {
		src := os.read_file(path) or { return error('cannot read ${path}') }
		for t in fcc.tokenize(src) {
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

// ---------- hooks ----------

// TargetHook validates -target and records it for the front end.
// Replaces the inline select_target / refuse_unimplemented_codegen calls.
pub struct TargetHook {
pub:
	plugin_name string = 'default-target-hook'
}

pub fn (p TargetHook) name() string {
	return p.plugin_name
}

pub fn (p TargetHook) stage() core.Stage {
	return .pre_parse
}

pub fn (p TargetHook) priority() int {
	return 0
}

pub fn (p TargetHook) run(mut ctx core.PipelineContext) ! {
	triple := if ctx.target == '' { ast.host_triple } else { ctx.target }
	if ast.abi_for_triple(triple) == none {
		return error('unknown target: ${triple} (known: ${ast.known_triples().join(', ')})')
	}
	if ctx.target != '' {
		fcc.set_target_triple(canonical_triple(triple))
	}
	if ctx.emit in ['asm', 's', 'obj', 'exe', 'o'] {
		if !ast.codegen_ready_for_triple(triple) {
			abi := ast.abi_for_triple(triple) or { return error('unknown target: ${triple}') }
			return error('no code generator for ${triple}: it needs the ${ast.abi_name_of(abi)} calling convention')
		}
	}
}

fn canonical_triple(t string) string {
	return match t {
		'amd64-windows', 'x86_64-windows-msvc', 'x86_64-pc-windows-msvc' { 'x86_64-windows' }
		'amd64-linux', 'x86_64-linux-gnu', 'x86_64-unknown-linux-gnu' { 'x86_64-linux' }
		else { t }
	}
}

// VerboseHook prints the effective pipeline when --verbose / verbose=true.
pub struct VerboseHook {
pub:
	plugin_name string = 'default-verbose-hook'
}

pub fn (p VerboseHook) name() string {
	return p.plugin_name
}

pub fn (p VerboseHook) stage() core.Stage {
	return .pre_parse
}

pub fn (p VerboseHook) priority() int {
	return 100
}

pub fn (p VerboseHook) run(mut ctx core.PipelineContext) ! {
	if ctx.verbose {
		eprintln('fcc: target=${if ctx.target == '' { ast.host_triple } else { ctx.target }} emit=${ctx.emit} inputs=${ctx.inputs}')
	}
}

// ---------- registration ----------

pub fn register_defaults() {
	core.register_input(CFileInput{})
	core.register_input(RawTextInput{})
	core.register_output(AsmOutput{})
	core.register_output(ObjOutput{})
	core.register_output(TokensOutput{})
	core.register_hook(TargetHook{})
	core.register_hook(VerboseHook{})
}
