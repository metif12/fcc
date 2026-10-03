module driver

import os
import src.vcc

// Command line handling and the invocation contract.
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
	// resource_root is -B, the tcc directory whose include/ and lib/ subtrees
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
	// verbose prints the command it would run.
	verbose bool
	// options_not_yet_honoured maps an accepted-but-unimplemented option to the
	// value that was given, so `--verbose` can report what is being ignored.
	options_not_yet_honoured map[string]string
}

pub const version = 'vcc 0.1.0 (phase 0)'

pub const usage = 'usage: vcc [options] file...

  -o <path>        write output to <path>
  -c               compile only, produce a relocatable object
  -shared          produce a DLL
  -std=<std>       language dialect (default: gnu11)
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
		if arg == '-o' {
			i++
			o.output = need_value(args, i, '-o')
		} else if arg.starts_with('-o') && arg.len > 2 {
			o.output = arg[2..]
		} else if arg == '-c' {
			o.compile_only = true
		} else if arg == '-E' || arg == '--dump-tokens' {
			o.dump_tokens = true
		} else if arg == '--preprocess' {
			o.preprocess_only = true
		} else if arg == '-shared' {
			o.shared = true
		} else if arg == '-S' {
			return error('-S is not supported yet; phase 2 will emit assembly directly')
		} else if arg.starts_with('-std=') {
			o.std = arg[5..]
		} else if arg == '-isystem' {
			i++
			o.sys_includes << need_value(args, i, '-isystem')
		} else if arg == '-include' {
			i++
			o.pre_includes << need_value(args, i, '-include')
		} else if arg == '-I' {
			i++
			o.includes << need_value(args, i, '-I')
		} else if arg.starts_with('-I') && arg.len > 2 {
			o.includes << arg[2..]
		} else if arg == '-D' {
			i++
			o.defines << need_value(args, i, '-D')
		} else if arg.starts_with('-D') && arg.len > 2 {
			o.defines << arg[2..]
		} else if arg == '-U' {
			i++
			o.undefines << need_value(args, i, '-U')
		} else if arg.starts_with('-U') && arg.len > 2 {
			o.undefines << arg[2..]
		} else if arg == '-L' {
			i++
			o.lib_paths << need_value(args, i, '-L')
		} else if arg.starts_with('-L') && arg.len > 2 {
			o.lib_paths << arg[2..]
		} else if arg == '-l' {
			i++
			o.libs << need_value(args, i, '-l')
		} else if arg.starts_with('-l') && arg.len > 2 {
			o.libs << arg[2..]
		} else if arg == '-B' {
			i++
			o.resource_root = need_value(args, i, '-B')
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
// The list mirrors `tcc_cached_main_flags` in vlang/v (driver.v:1042), which is
// the set V actually passes through for a TinyCC invocation.
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
	'-idirafter'
	'--sysroot',
]

fn need_value(args []string, i int, flag string) string {
	if i >= args.len {
		return panic('option ${flag} requires an argument')
	}
	return args[i]
}

// main runs the command line. Phase 0 stops after reporting, which is
// deliberate: a compiler that parses its flags and then prints "not
// implemented" is testable, where one that half-compiles a file is not.
pub fn main(args []string) {
	o := parse_args(args) or {
		eprintln('vcc: ${err.msg()}')
		eprintln(usage)
		exit(1)
	}
	if o.show_version {
		println(version)
		return
	}
	if o.show_help {
		println(usage)
		return
	}
	if o.verbose {
		eprintln('vcc: ${o.summary()}')
	}
	if o.dump_tokens {
		dump_tokens(o)
		return
	}
	if o.preprocess_only {
		dump_preprocessed(o)
		return
	}
	eprintln('vcc: phase 1 — the command line is parsed and the preprocessor runs, but no C is compiled yet')
	exit(1)
}

// preprocess_only mirrors `-E`: run the preprocessor and print the resulting
// tokens. It is how phase 1 is validated, since every phase-2 acceptance criterion
// depends on the front end being right.
fn dump_preprocessed(o &Options) {
	mut p := vcc.preprocessor(o.includes, o.sys_includes)
	for spec in o.defines {
		p.define_from_option(spec)
	}
	for name in o.undefines {
		p.undefine(name)
	}
	p.define_builtins()
	mut failed := false
	for path in o.inputs {
		r := p.run(path)
		for e in r.errors {
			eprintln('${path}: ${e}')
			failed = true
		}
		println('--- ${path}')
		for t in r.tokens {
			if t.kind == .eof {
				continue
			}
			println('${t.line.disp_line}: ${t.kind} "${t.text}"')
		}
	}
	if failed {
		exit(1)
	}
}

// dump_tokens tokenizes every input and writes the stream to stdout.
//
// Failing on one input does not stop the others: the point of this mode is to
// sweep a whole corpus and find every file that breaks the lexer, not to report
// the first one.
fn dump_tokens(o &Options) {
	mut failed := false
	for path in o.inputs {
		src := os.read_file(path) or {
			eprintln('vcc: cannot read ${path}: ${err.msg()}')
			failed = true
			continue
		}
		toks := vcc.tokenize(src)
		println('--- ${path}')
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
			println('${line}: ${t.kind} "${t.text}"${flagtext}${extra}')
		}
	}
	if failed {
		exit(1)
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
