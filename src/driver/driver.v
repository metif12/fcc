module driver

import os
import src.ast
import src.backend
import src.coff
import src.core
import src.ext
import src.fcc
import src.masm

// Command line handling and the invocation contract.

// v_in_main_func is set while emitting V for C's `main`, whose return value V
// does not accept.
// (no module-level mutable state; context is passed explicitly)
//
// The contract `vcc` has to satisfy is written out in docs/CONTRACT.md. This
// module is where it becomes code, and `contract_test.v` asserts that the V
// compiler's own source still contains every item listed there — so if V's
// driver changes its requirements, this project finds out.

pub struct Options {
pub mut:
	inputs []string
	// output is the path given to -o, empty when none was given.
	output string
	// compile_only mirrors `-c`: stop after producing a relocatable object.
	compile_only bool
	// shared mirrors `-shared`: produce a DLL.
	shared bool
	// std is the value of -std=, defaulting to the dialect V emits.
	std string = 'gnu11'
	// target is the -target triple, empty when not given (meaning the host target).
	// Carried here rather than in module state so that `resolve_triple` and
	// `summary` are pure functions of their argument and tests do not leak state
	// across calls in one process.
	target string
	// includes are -I paths, in order, later entries taking precedence.
	includes []string
	// sys_includes are -isystem paths.
	sys_includes []string
	// defines are -D macros, as alternating name/value pairs.
	defines []string
	// undefines are -U names.
	undefines []string
	// lib_paths are -L paths.
	lib_paths []string
	// libs are -l names, in order, because archive order is significant.
	libs []string
	// objects are inputs that are already objects.
	objects []string
	// define_backtrace mirrors `-bt`, which V passes as `-bt25`.
	define_backtrace bool
	backtrace_frames int
	// unicode_subsystem mirrors -municode, which selects the `wmain` entry point.
	unicode_subsystem bool
	// subsystem is one of `console`, `windows` or `auto`.
	subsystem string = 'auto'
	// stack_size is the default stack reserve, from -Wl,--stack=N.
	stack_size int
	// suppress_warnings mirrors -w.
	suppress_warnings bool
	// fatal_implicit_fn mirrors -Werror=implicit-function-declaration, the only
	// warning V promotes to an error.
	fatal_implicit_fn bool
	// pre_includes are -include files, processed before the main input.
	pre_includes []string
	// resource_root is -B, the resource directory whose include/ and lib/ subtrees
	// supply headers and archives.
	resource_root string
	// show_version and show_help stop before any compilation.
	show_version bool
	show_help    bool
	// dump_tokens mirrors `-E`: tokenize and print the stream instead of
	// compiling. It is phase 1's first acceptance signal, so it is a real option
	// rather than a debug leftover.
	dump_tokens bool
	// preprocess_only mirrors `-E` after the preprocessor exists: run phase 1 and
	// print the result.
	preprocess_only bool
	// dump_ast runs the parser and prints what it produced. It is how phase 1 is
	// signed off — see `dump_ast`.
	dump_ast bool
	// emit_v mirrors `--to-v`: translate C to V source instead of compiling.
	emit_v bool
	// emit_v_bindings mirrors `--to-v-bindings`: emit V bindings to the C
	// (c2v-style) instead of translating.
	emit_v_bindings bool
	// emits lists `--emit <fmt>[=<path>]`, in flag order. Empty means the
	// legacy single-mode flags (-S, -c, ...) own the invocation; non-empty
	// means every listed output is produced, each to its own path.
	emits []string
	// emit_asm is -S: write assembly text instead of an object.
	emit_asm bool
	// extern_as mirrors `--extern-as`: assemble `-c` output with the system
	// `as` instead of the native phase-3 machine-code emitter. It exists for
	// bisection, so a native-encoder defect can be isolated from the frontend.
	extern_as bool
	// verbose prints the command it would run.
	verbose bool
	// options_not_yet_honoured maps an accepted-but-unimplemented option to the
	// value that was given, so `--verbose` can report what is being ignored.
	options_not_yet_honoured map[string]string
}

// `-target` is carried on `Options.target` (see the field above). It used to live
// in a `__global` in this file, and that global is what put the access violation
// into every compile: `parse_args` wrote it, `resolve_triple` read it back, and
// the read returned a pointer that was not the one written. Moving the triple
// onto the options struct removed the fault on every input measured (see
// docs/PLAN.md for the bisect). The mechanism was not established — a standalone
// `__global string` round-trip through a function returning a struct does not
// misbehave under the same V — so this comment records the change and its
// measured effect, not a cause.

pub const version = 'fcc 0.1.0 (phase 0)'

pub const usage = 'usage: fcc [options] file...

  -o <path>        write output to <path>
  -c               compile only, produce a relocatable object
  --emit <fmt>[=<path>]  produce one more output (repeatable);
                   fmt is asm, obj, tokens, preprocessed, ast, v, v-bindings;
                   no =path takes -o (single output) or main-stem defaults
  -shared          produce a DLL
  -std=<std>       language dialect (default: gnu11)
  -target=<triple> machine to compile for (default: x86_64-windows)
  -I<dir>          add an include search directory
  -isystem <dir>   add a system include search directory
  -D<name>[=val]   define a macro
  -U<name>         undefine a macro
  -L<dir>          add a library search directory
  -l<name>         link against a library
  -include <file>  process <file> before the main input
  -B<dir>          resource root holding include/ and lib/
  -bt<n>           enable the runtime backtrace with <n> frames
  -municode        use the wmain entry point
  -mconsole        use the console subsystem
  -mwindows        use the GUI subsystem
  -Wl,--stack=<n>  set the default stack reserve
  -w               suppress warnings
  -Werror=implicit-function-declaration
                   make an implicit function declaration an error
  --dump-ast    parse and print the declarations that were read
  --to-v        translate C to V source
  --to-v-bindings  emit V bindings to the C (c2v-style)
  --preprocess  preprocess only, print the resulting tokens
  --extern-as   assemble with the system `as` instead of the native emitter
  --version        print the version
  --help           print this message
  '

// parse_args turns a raw argument list into options.
//
// A malformed argument is an error rather than a warning, because V builds its
// output with whatever flags it computed: a silently dropped `-I` would produce
// a confusing failure much later, in the middle of a large C file.
//
// Note the asymmetry, which is deliberate: an option vcc understands but cannot
// yet honour is recorded via `note_unimplemented_option` and the run continues,
// because refusing it would make vcc unusable as a drop-in. An option vcc does
// not recognise at all is a hard error, because silently dropping an unknown
// flag produces a wrong binary with no diagnostic.
pub fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0
	for i < args.len {
		arg := args[i]
		if arg == '--version' {
			o.show_version = true
			return o
		}
		if arg == '--help' {
			o.show_help = true
			return o
		}
		if arg == '--verbose' {
			o.verbose = true
			i++
			continue
		}
		if arg == '--config' {
			// Consumed by load_effective_config before parsing; skip value here
			// so config-aware invocations still parse as legacy compiles.
			// The value is still required: a trailing bare `--config` must
			// fail here rather than silently compiling with defaults.
			i++
			need_value(args, i, '--config') or { return err }
			i++
			continue
		}
		if arg.starts_with('--config=') {
			i++
			continue
		}
		if arg == '-o' {
			i++
			o.output = need_value(args, i, '-o') or { return err }
		} else if arg.starts_with('-o') && arg.len > 2 {
			o.output = arg[2..]
		} else if arg == '-c' {
			o.compile_only = true
		} else if arg == '-E' || arg == '--preprocess' {
			// `-E` is the reference compiler's and gcc's "preprocess and stop". It was aliased to the
			// tokenizer dump, so it printed raw `#include` lines and never computed the
			// expansion it exists to show. Every conclusion drawn from `-E` about the
			// preprocessor was really a conclusion about the lexer.
			o.preprocess_only = true
		} else if arg == '--dump-tokens' {
			o.dump_tokens = true
		} else if arg == '--dump-ast' {
			o.dump_ast = true
		} else if arg == '--to-v' {
			o.emit_v = true
		} else if arg == '--to-v-bindings' {
			o.emit_v_bindings = true
		} else if arg == '--emit' {
			i++
			o.emits << need_value(args, i, '--emit') or { return err }
		} else if arg.starts_with('--emit=') {
			o.emits << arg['--emit='.len..]
		} else if arg == '--extern-as' {
			o.extern_as = true
		} else if arg == '-shared' {
			o.shared = true
		} else if arg == '-S' {
			o.emit_asm = true
		} else if arg.starts_with('-std=') {
			o.std = arg[5..]
		} else if arg.starts_with('-target=') {
			o.target = arg[8..]
			if o.target == '' {
				return error('option ${arg} requires a target triple')
			}
		} else if arg == '-target' {
			i++
			o.target = need_value(args, i, '-target') or { return err }
			if o.target == '' {
				return error('option ${arg} requires a target triple')
			}
		} else if arg == '-isystem' {
			i++
			o.sys_includes << need_value(args, i, '-isystem') or { return err }
		} else if arg == '-include' {
			i++
			o.pre_includes << need_value(args, i, '-include') or { return err }
		} else if arg == '-I' {
			i++
			o.includes << need_value(args, i, '-I') or { return err }
		} else if arg.starts_with('-I') && arg.len > 2 {
			o.includes << arg[2..]
		} else if arg == '-D' {
			i++
			o.defines << need_value(args, i, '-D') or { return err }
		} else if arg.starts_with('-D') && arg.len > 2 {
			o.defines << arg[2..]
		} else if arg == '-U' {
			i++
			o.undefines << need_value(args, i, '-U') or { return err }
		} else if arg.starts_with('-U') && arg.len > 2 {
			o.undefines << arg[2..]
		} else if arg == '-L' {
			i++
			o.lib_paths << need_value(args, i, '-L') or { return err }
		} else if arg.starts_with('-L') && arg.len > 2 {
			o.lib_paths << arg[2..]
		} else if arg == '-l' {
			i++
			o.libs << need_value(args, i, '-l') or { return err }
		} else if arg.starts_with('-l') && arg.len > 2 {
			o.libs << arg[2..]
		} else if arg == '-B' {
			i++
			o.resource_root = need_value(args, i, '-B') or { return err }
		} else if arg.starts_with('-B') && arg.len > 2 {
			o.resource_root = arg[2..]
		} else if arg.starts_with('-bt') {
			n := arg[3..]
			o.define_backtrace = true
			o.backtrace_frames = if n.len == 0 { 25 } else { n.int() }
		} else if arg == '-municode' {
			o.unicode_subsystem = true
		} else if arg == '-mconsole' {
			o.subsystem = 'console'
		} else if arg == '-mwindows' {
			o.subsystem = 'windows'
		} else if arg.starts_with('-Wl,--stack=') {
			o.stack_size = arg[12..].int()
		} else if arg == '-w' {
			o.suppress_warnings = true
		} else if arg == '-Werror=implicit-function-declaration' {
			o.fatal_implicit_fn = true
		} else if arg in options_that_consume_an_operand {
			// Accepted for contract compatibility. The preprocessor that will
			// honour these is phase 1; the operand must still be consumed now so
			// it is not mistaken for an input path.
			i++
			if i < args.len && !(arg in ['-I', '-D', '-U', '-L', '-l', '-include', '-isystem']) {
				o.note_unimplemented_option(arg, args[i])
			}
		} else if arg.starts_with('-W') || arg.starts_with('-O') || arg.starts_with('-f')
			|| arg.starts_with('-m') || arg.starts_with('-g') || arg.starts_with('-std')
		{
			// Optimization and warning-selection flags are accepted and ignored.
			// V computes a large flag set for other compilers, and refusing the
			// ones irrelevant to vcc would make it unusable as a drop-in.
		} else if arg.starts_with('-') && arg.len > 1 {
			return error('unrecognized option: ${arg}')
		} else {
			o.classify_input(arg)
		}
		i++
	}
	if o.inputs.len == 0 && !o.show_version && !o.show_help {
		return error('no input files')
	}
	return o
}

// classify_input sorts a positional argument by extension. An object input is
// separated from a source input because it is never compiled, only linked.
fn (mut o Options) classify_input(path string) {
	lower := path.to_lower()
	if lower.ends_with('.o') || lower.ends_with('.obj') || lower.ends_with('.a')
		|| lower.ends_with('.lib') || lower.ends_with('.dll') {
		o.objects << path
		return
	}
	o.inputs << path
}

// options_that_consume_an_operand are preprocessor and search-path options whose
// value is a separate argument. They are listed here so the operand is consumed
// rather than misread as an input file, which is the failure mode that would
// otherwise turn `-imacros m.h` into a mysterious second translation unit.
//
// The list mirrors the cached main flags in vlang/v (driver.v:1042), which is
// the set V actually passes through for a C compiler invocation.
// note_unimplemented_option records an option that was accepted for
// compatibility but whose effect the compiler does not implement yet. Phase 1
// empties the `-include`, `-imacros` and `-isystem` entries; the rest belong to
// later phases.
//
// It is a field rather than a log line so that `--verbose` can report what is
// being ignored. A dropped option that V depends on is a correctness problem
// that should be visible, not something discovered when a build quietly produces
// the wrong answer.
fn (mut o Options) note_unimplemented_option(flag string, value string) {
	o.options_not_yet_honoured[flag] = value
}

const options_that_consume_an_operand = [
	'-I'
	'-D'
	'-U'
	'-include'
	'-imacros'
	'-isystem'
	'-iquote'
	'-idirafter'
	'-iprefix'
	'-iwithprefix'
	'-iwithprefixbefore'
	'-isysroot'
	'--sysroot',
]

fn need_value(args []string, i int, flag string) !string {
	if i >= args.len {
		return error('option ${flag} requires an argument')
	}
	return args[i]
}

// resolve_triple turns the `-target` value into the canonical triple to compile for.
//
// An unknown triple is an error rather than a warning, and it is the one place that
// decides: a target silently falling back to the host would emit code for the wrong
// machine under the right machine's name, which is the failure this project cares
// most about not shipping. The error lists the spellings that are accepted, taken
// from the table rather than written out here, so the list cannot drift.
//
// It returns the *canonical* triple rather than what was typed, so an alias and its
// target resolve to the same name — and it returns a string rather than a
// `&ast.Target`, so that nothing is allocated before the first compilation. See
// `current_target` in `src/fcc/types.v` for why that matters.
fn resolve_triple(o &Options) !string {
	if o.target == '' {
		return ast.host_triple
	}
	// A target the front end can type but the backend cannot emit is still a
	// known target: `--preprocess` and `--dump-ast` must work on it, and the
	// refusal happens later, in `refuse_unimplemented_codegen`, only when code
	// generation is actually requested.
	if ast.target_by_triple(o.target) == none {
		return error('unknown target: ${o.target} (known: ${ast.known_triples().join(', ')})')
	}
	return match o.target {
		'amd64-windows', 'x86_64-windows-msvc', 'x86_64-pc-windows-msvc' { 'x86_64-windows' }
		'amd64-linux', 'x86_64-linux-gnu', 'x86_64-unknown-linux-gnu' { 'x86_64-linux' }
		'aarch64-linux-gnu', 'aarch64-unknown-linux-gnu', 'arm64-linux' { 'aarch64-linux' }
		else { o.target }
	}
}

// select_target validates `-target` and records it for the front end.
//
// It is called once per process, before anything is parsed. The front end builds
// the target itself, on first use, so nothing here allocates.
//
// The default is not written. `current_target` already answers the host target
// when nothing has been recorded, so the overwhelmingly common run — no `-target`
// at all — leaves the front end's globals exactly as the process found them.
fn select_target(o &Options) !string {
	triple := resolve_triple(o) or { return err }
	if o.target != '' {
		fcc.set_target_triple(triple)
	}
	return triple
}

// refuse_unimplemented_codegen stops before code generation for a target whose
// calling convention the backend does not implement.
//
// The front end can type a target the backend cannot emit, and the two facts are
// independent: the data model and the predefined macros are properties of the
// machine, while the ABI is what `abi.v` describes. Emitting the Microsoft x64 ABI
// for a target named `x86_64-linux` would produce a file that assembles, links and
// runs with the wrong argument registers and the wrong `va_list` — so the refusal
// is the point of having the target separate from the ABI, not a limitation of it.
fn refuse_unimplemented_codegen(o &Options) ! {
	triple := resolve_triple(o) or { return err }
	if ast.codegen_ready_for_triple(triple) {
		return
	}
	// A target the front end can type but the backend cannot emit is not an
	// "unknown target": it is known, and the refusal has to say so, otherwise a
	// user who passed a recognised triple gets a misleading diagnostic.
	if ast.target_by_triple(triple) == none {
		return error('unknown target: ${triple}')
	}
	abi := ast.abi_for_triple(triple) or { return error('no code generator for ${triple}: this architecture has no backend yet (front end only). --preprocess and --dump-ast accept this target.') }
	return error('no code generator for ${triple}: it needs the ' +
		'${ast.abi_name_of(abi)} calling convention, and fcc implements only ' +
		'${ast.abi_name_of(.microsoft_x64)}. The front end is target-aware, so ' +
		'--preprocess and --dump-ast accept this target.')
}

// ensure_extensions registers every default extension exactly once.
// All current behaviour lives behind these registrations, so disabling one
// in fcc.toml ([plugin."default-..."] enabled=false) really removes it.
__global extensions_ready bool

fn ensure_extensions() {
	if extensions_ready {
		return
	}
	extensions_ready = true
	ext.register_defaults()
	ext.register_extra_outputs()
	ext.register_cli()
	// Example language plugins live behind their own register call so the
	// pattern stays visible; they still work out of the box.
	ext.register_bf()
	ext.register_bash()
	ext.register_blip()
}

// load_effective_config finds and parses fcc.toml / fcc.blip.
// --config <path> wins; otherwise the cwd is searched. Missing file = defaults.
fn load_effective_config(args []string) core.FccConfig {
	mut explicit := ''
	for i, a in args {
		if a == '--config' && i + 1 < args.len {
			explicit = args[i + 1]
		} else if a.starts_with('--config=') {
			explicit = a['--config='.len..]
		}
	}
	if explicit != '' {
		mut c := core.load_config_file(explicit) or {
			eprintln('fcc: cannot load config ${explicit}: ${err.msg()}')
			exit(1)
			return core.default_config()
		}
		c.merge_build_tasks(os.getwd())
		return c
	}
	found := core.discover_config(os.getwd())
	if found == '' {
		mut c := core.default_config()
		c.merge_build_tasks(os.getwd())
		return c
	}
	mut cfg := core.load_config_file(found) or {
		// A broken config is fatal — except for the `plugin` verb, which is
		// the tool that repairs configs. Bricking the repair tool behind
		// the file it repairs would leave no way out.
		if args.len > 0 && args[0] == 'plugin' {
			eprintln('fcc: cannot load config ${found}: ${err.msg()} (continuing with defaults)')
			mut c := core.default_config()
			c.merge_build_tasks(os.getwd())
			return c
		}
		eprintln('fcc: cannot load config ${found}: ${err.msg()}')
		exit(1)
		return core.default_config()
	}
	cfg.merge_build_tasks(os.getwd())
	return cfg
}

// pipeline_emit_for maps a parsed legacy invocation onto a plugin-pipeline
// emit format, or '' when the legacy path owns the mode. --to-v has no
// output plugin and -E/--dump-tokens work on raw bytes, so those stay legacy.
fn pipeline_emit_for(o &Options) string {
	if o.dump_ast {
		return 'ast'
	}
	if o.emit_asm {
		return 'asm'
	}
	if o.compile_only {
		return 'obj'
	}
	if !o.dump_tokens && !o.preprocess_only && !o.emit_v && !o.show_version && !o.show_help {
		return 'exe'
	}
	return ''
}

// any_input_claimed_by_plugin reports an input the legacy C path cannot
// handle but a non-default input plugin claims (.bf today). Default plugins
// keep the legacy path, so stock behavior is unchanged.
fn any_input_claimed_by_plugin(o &Options, cfg &core.FccConfig) bool {
	for path in o.inputs {
		if input_claimed_by_plugin(path, cfg) {
			return true
		}
	}
	return false
}

fn input_claimed_by_plugin(path string, cfg &core.FccConfig) bool {
	lower := path.to_lower()
	if lower.ends_with('.c') || lower.ends_with('.h') {
		return false
	}
	p := core.find_input(path) or { return false }
	if p.name().starts_with('default-') {
		return false
	}
	return !core.is_plugin_disabled(p.name(), cfg)
}

// run_pipeline_modes runs the plugin pipeline for a legacy-shaped invocation
// whose inputs belong to non-default input plugins.
fn run_pipeline_modes(o &Options, emit string) {
	mut ctx := core.PipelineContext{
		inputs:       o.inputs.clone()
		output:       o.output
		target:       o.target
		std:          o.std
		includes:     o.includes.clone()
		sys_includes: o.sys_includes.clone()
		defines:      o.defines.clone()
		undefines:    o.undefines.clone()
		pre_includes: o.pre_includes.clone()
		emit:         emit
		verbose:      o.verbose
	}
	core.run_pipeline(mut ctx, o.inputs) or {
		eprintln('fcc: ${err.msg()}')
		for d in ctx.diagnostics {
			eprintln(d)
		}
		exit(1)
	}
	for d in ctx.diagnostics {
		eprintln(d)
	}
	if ctx.failed {
		exit(1)
	}
}

// main runs the command line. Phase 0 stops after reporting, which is
// deliberate: a compiler that parses its flags and then prints "not
// implemented" is testable, where one that half-compiles a file is not.
pub fn main(args []string) {
	ensure_extensions()
	cfg := load_effective_config(args)
	// Config owns enablement and declares external plugins: install the
	// disable set, then register config-declared inputs, before any dispatch
	// or pipeline decision consults the registries.
	core.apply_config(cfg)
	ext.register_external_inputs(cfg)
	// `fcc <verb>` (build / plugin / config / init / external fcc-*) is
	// handled by the CLI plugin registry before legacy flag parsing, so
	// new commands never disturb the historic `fcc [options] file...` shape.
	// Legacy flags (starting with `-`) and direct file args skip dispatch.
	if args.len > 0 && !args[0].starts_with('-') {
		code := core.dispatch_verb(args, cfg)
		if code >= 0 {
			exit(code)
		}
		// Unknown verb: if it looks like a word (not a file), hint plugins.
		if !core.is_legacy_flag(args[0]) {
			eprintln('fcc: unknown command "${args[0]}"')
			eprintln(core.cli_help())
			exit(1)
		}
	}
	mut o := parse_args(args) or {
		eprintln('fcc: ${err.msg()}')
		eprintln(usage)
		exit(1)
	}
	// Config file supplies defaults CLI did not set (CLI always wins).
	if o.target == '' && cfg.target != '' {
		o.target = cfg.target
	}
	if o.std == 'gnu11' && cfg.std != '' && cfg.std != 'gnu11' {
		o.std = cfg.std
	}
	if o.output == '' && cfg.output != '' {
		o.output = cfg.output
	}
	if o.includes.len == 0 && cfg.includes.len > 0 {
		o.includes = cfg.includes.clone()
	}
	if o.defines.len == 0 && cfg.defines.len > 0 {
		o.defines = cfg.defines.clone()
	}
	if o.inputs.len == 0 && cfg.inputs.len > 0 {
		for inp in cfg.inputs {
			o.classify_input(inp)
		}
	}
	if o.show_version {
		println(version)
		return
	}
	if o.show_help {
		println(usage)
		println('')
		println(core.cli_help())
		return
	}
	if o.verbose {
		eprintln('fcc: ${o.summary()}')
	}
	// Validated once, before any mode runs, and recorded by name: the front end builds
	// the target on first use rather than here.
	select_target(&o) or {
		eprintln('fcc: ${err.msg()}')
		exit(1)
	}
	if o.emits.len > 0 || cfg.outputs.len > 0 {
		mut reqs := resolve_outputs(&o, &cfg) or {
			eprintln('fcc: ${err.msg()}')
			exit(1)
		}
		if reqs.len == 0 {
			run_single_output(&o, &cfg)
			return
		}
		run_multi_output(&o, &cfg, reqs)
		return
	}
	run_single_output(&o, &cfg)
}

// dump_ast preprocesses and parses every input, then prints what the parser produced.
//
// It is the acceptance signal for phase 1: the sweep that matters is running it over a
// corpus and reading the diagnostics, not checking that it exits zero. So every input
// is attempted even after one fails, and the exit code reflects whether anything was
// reported.
fn dump_ast(o &Options) {
	mut failed := false
	mut text := ''
	for path in o.inputs {
		mut p := fcc.preprocessor(o.includes, o.sys_includes)
		for spec in o.defines {
			p.define_from_option(spec)
		}
		for name in o.undefines {
			p.undefine(name)
		}
		p.define_builtins()
		pre := p.run(path)
		for e in pre.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		parsed := fcc.parse_tokens(pre.tokens, path, p.packs)
		failed = report(parsed.errors, parsed.warnings) || failed
		text += '--- ${path}\n' + parsed.dump()
	}
	if failed {
		exit(1)
	}
	if o.output == '' {
		print(text)
	} else {
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}

// report prints a translation unit's diagnostics and reports whether any of them was
// an error.
//
// Warnings are printed and do not stop the run, which is the whole reason they are a
// separate list: the reference compiler prints `implicit declaration of function '_gmtime64_s'` and exits
// 0, and gcc treats it as gnu11's implicit-declaration warning, while folding it into
// `errors` refused a program both of them accept. A warning's exit code is what makes
// it a warning.
//
// It returns rather than taking a mutable flag because this V build rejects a mutable
// scalar argument outright.
fn report(errors []string, warnings []string) bool {
	mut any := false
	for e in errors {
		eprintln(e)
		any = true
	}
	for w in warnings {
		eprintln(w)
	}
	return any
}

// emit_asm implements -S: run the front end and write the assembly text.
//
// The output goes to `-o` when there is one and to standard output otherwise,
// which is what the reference compiler does and what lets it be piped straight into `as`.
//
// Every input is attempted even after one fails, so a file the front end rejects
// does not hide the diagnostics of the file after it.
fn emit_asm(o &Options) {
	refuse_unimplemented_codegen(o) or {
		eprintln('fcc: ${err.msg()}')
		exit(1)
	}
	mut all := []string{}
	mut failed := false
	mut first := true

	for path in o.inputs {
		mut p := fcc.preprocessor(o.includes, o.sys_includes)
		p.define_builtins()
		pre := p.run(path)
		for e in pre.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		// parsed is mutable so that mut parsed.globals below is a reference to
		// the result's own slice rather than to a temporary copy of its header. A copy
		// is silently empty, and an empty globals list produces a one-line assembly
		// file that assembles and links into nothing.
		mut parsed := fcc.parse_tokens(pre.tokens, path, p.packs)
		failed = report(parsed.errors, parsed.warnings) || failed
		if parsed.errors.len > 0 {
			// Nothing is generated for a translation unit the front end rejected. It
			// used to be skipped, which left a one-line file behind that the assembler
			// accepted and the linker then failed with `undefined reference to WinMain`
			// — a message about the *link* that was really about the parse. The
			// diagnostics above are the useful output, so no file is written at all.
			continue
		}
		mut g := backend.AsmGen{}
		unit, errs := g.gen(mut parsed.globals)
		for e in errs {
			eprintln(e)
			failed = true
		}
		if !first {
			all << ''
		}
		first = false
		all << unit
	}

	if failed {
		exit(1)
	}

	text := all.join('\n')
	if o.output == '' {
		print(text)
	} else {
		// `os.write_file` returns a result, so the failure is caught with `or` rather
		// than compared: there is no value to compare, and the earlier spelling that
		// compared one was never a working check.
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}

// emit_obj implements -c: compile to a relocatable object.
//
// Phase 3 assembles in-process: the text above goes through masm (a machine-code
// emitter for exactly the dialect AsmGen prints) and the coff writer, so no
// external assembler is involved. `--extern-as` keeps the old behavior (write
// the .s file and shell to `as`) as a bisection escape hatch; the Linux target
// still uses WSL `as` because there is no native ELF writer yet.
fn emit_obj(o &Options) {
	refuse_unimplemented_codegen(o) or {
		eprintln('fcc: ${err.msg()}')
		exit(1)
	}
	mut all := []string{}
	mut failed := false
	mut first := true

	for path in o.inputs {
		mut p := fcc.preprocessor(o.includes, o.sys_includes)
		p.define_builtins()
		pre := p.run(path)
		for e in pre.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		mut parsed := fcc.parse_tokens(pre.tokens, path, p.packs)
		failed = report(parsed.errors, parsed.warnings) || failed
		if parsed.errors.len > 0 {
			continue
		}
		mut g := backend.AsmGen{}
		unit, errs := g.gen(mut parsed.globals)
		for e in errs {
			eprintln(e)
			failed = true
		}
		if !first {
			all << ''
		}
		first = false
		all << unit
	}

	if failed {
		exit(1)
	}

	text := all.join('\n')
	if fcc.current_target().abi != .sysv_x64 && !o.extern_as {
		masm_out := masm.assemble(text) or {
			eprintln('fcc: assemble: ${err.msg()}')
			exit(1)
		}
		coff.write_object(masm_out, o.output) or {
			eprintln('fcc: ${err.msg()}')
			exit(1)
		}
		return
	}
	// Write assembly to a temp file, invoke as, then clean up.
	tmp_s := o.output.all_before_last('.') + '.s'
	os.write_file(tmp_s, text) or {
		eprintln('fcc: cannot write ${tmp_s}')
		exit(1)
	}
	// Invoke the system assembler. For Linux targets, use WSL's assembler to
	// produce a proper ELF object.
	mut res := os.Result{}
	if fcc.current_target().abi == .sysv_x64 {
		// Convert Windows path to WSL path for the .s file.
		// Convert Windows absolute path to WSL /mnt/c/... path.
		cwd := os.getwd()
		wsl_s := '/mnt/c/' + cwd.replace('\\', '/').to_lower().replace('c:/', '') + '/' + tmp_s.replace('\\', '/')
		wsl_o := '/mnt/c/' + cwd.replace('\\', '/').to_lower().replace('c:/', '') + '/' + o.output.replace('\\', '/')
		res = os.exec(['wsl', 'as', wsl_s, '-o', wsl_o])
	} else {
		res = os.exec(['as', tmp_s, '-o', o.output])
	}
	if res.exit_code != 0 {
		eprintln('fcc: assembler failed: ${res.output}')
		exit(1)
	}
	// Clean up temp assembly file.
	os.rm(tmp_s) or {}
}

// preprocess_only mirrors `-E`: run the preprocessor and print the resulting
// tokens. It is how phase 1 is validated, since every phase-2 acceptance criterion
// depends on the front end being right.
fn dump_preprocessed(o &Options) {
	mut p := fcc.preprocessor(o.includes, o.sys_includes)
	for spec in o.defines {
		p.define_from_option(spec)
	}
	for name in o.undefines {
		p.undefine(name)
	}
	p.define_builtins()
	mut failed := false
	mut lines := []string{}
	for path in o.inputs {
		r := p.run(path)
		for e in r.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		lines << '--- ${path}'
		for t in r.tokens {
			if t.kind == .eof {
				continue
			}
			lines << '${t.line.disp_line}: ${t.kind} "${t.text}"'
		}
	}
	if failed {
		exit(1)
	}
	if o.output == '' {
		for l in lines {
			println(l)
		}
	} else {
		text := if lines.len > 0 { lines.join('\n') + '\n' } else { '' }
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}

// dump_tokens tokenizes every input and writes the stream to stdout.
//
// Failing on one input does not stop the others: the point of this mode is to
// sweep a whole corpus and find every file that breaks the lexer, not to report
// the first one.
fn dump_tokens(o &Options) {
	mut failed := false
	mut lines := []string{}
	for path in o.inputs {
		src := os.read_file(path) or {
			eprintln('fcc: cannot read ${path}: ${err.msg()}')
			failed = true
			continue
		}
		toks := fcc.tokenize(src)
		lines << '--- ${path}'
		for t in toks {
			if t.kind == .eof {
				continue
			}
			line := t.line.disp_line
			mut flags := []string{}
			if t.at_bol {
				flags << 'bol'
			}
			if t.has_space {
				flags << 'sp'
			}
			extra := match t.kind {
				.num_ {
					if t.text.starts_with('"') {
						' str=${t.str_data.bytestr()}'
					} else {
						' val=${t.val} fval=${t.fval}'
					}
				}
				.str_ { ' str=${t.str_data.bytestr()}' }
				.keyword { ' kw=${t.text}' }
				else { '' }
			}
			flagtext := if flags.len == 0 { '' } else { ' [${flags.join(',')}]' }
			lines << '${line}: ${t.kind} "${t.text}"${flagtext}${extra}'
		}
	}
	if failed {
		exit(1)
	}
	if o.output == '' {
		for l in lines {
			println(l)
		}
	} else {
		text := if lines.len > 0 { lines.join('\n') + '\n' } else { '' }
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}

// summary renders the parsed options, which is what `--verbose` prints and what
// the contract test compares against a hand-written expectation.
pub fn (o &Options) summary() string {
	mut b := []string{}
	if o.compile_only {
		b << '-c'
	}
	if o.shared {
		b << '-shared'
	}
	b << '-std=${o.std}'
	// The effective target rather than the spelling given, because the value that
	// matters to a reader of `--verbose` is the one the type model came from: an
	// alias resolves to the target's own name. An unknown spelling is echoed rather
	// than replaced, because `resolve_triple` is what reports it and a summary that
	// invented a target would be worse than one that shows the question.
	b << '-target ${if o.target == '' { ast.host_triple } else { o.target }}'
	b << o.inputs
	if o.output != '' {
		b << '-o ${o.output}'
	}
	if o.define_backtrace {
		b << '-bt${o.backtrace_frames}'
	}
	for flag, value in o.options_not_yet_honoured {
		b << '(ignored ${flag} ${value})'
	}
	return b.join(' ')
}

// emit_v implements `--to-v`: translate each input's C to V source.
//
// It is a best-effort, readable port rather than a guaranteed compilable one:
// constructs the V side has no equivalent for are left as comments naming the
// kind, so the output never silently drops a statement.
fn emit_v(o &Options) {
	mut all := []string{}
	mut failed := false

	for path in o.inputs {
		mut p := fcc.preprocessor(o.includes, o.sys_includes)
		for spec in o.defines {
			p.define_from_option(spec)
		}
		for name in o.undefines {
			p.undefine(name)
		}
		p.define_builtins()
		pre := p.run(path)
		for e in pre.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		mut parsed := fcc.parse_tokens(pre.tokens, path, p.packs)
		failed = report(parsed.errors, parsed.warnings) || failed
		if parsed.errors.len > 0 {
			continue
		}

		all << '// translated from ${path}'
		all << vemit_unit(parsed.globals, parsed.typedefs)
	}

	if failed {
		exit(1)
	}

	text := all.join('\n')
	if o.output == '' {
		print(text)
	} else {
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}

fn emit_v_bindings(o &Options) {
	mut all := []string{}
	mut failed := false

	for path in o.inputs {
		mut p := fcc.preprocessor(o.includes, o.sys_includes)
		for spec in o.defines {
			p.define_from_option(spec)
		}
		for name in o.undefines {
			p.undefine(name)
		}
		p.define_builtins()
		pre := p.run(path)
		for e in pre.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		mut parsed := fcc.parse_tokens(pre.tokens, path, p.packs)
		failed = report(parsed.errors, parsed.warnings) || failed
		if parsed.errors.len > 0 {
			continue
		}

		all << '// bindings for ${path}'
		all << vemit_bindings_unit(parsed.globals, parsed.typedefs)
	}

	if failed {
		exit(1)
	}

	text := all.join('\n')
	if o.output == '' {
		print(text)
	} else {
		os.write_file(o.output, text) or {
			eprintln('fcc: cannot write ${o.output}')
			exit(1)
		}
	}
}
