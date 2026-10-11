module main

import os

// The chibicc behavioural suite, run against vcc.
//
// This is the project's strongest correctness signal: chibicc's tests compare
// *runtime behaviour* against gcc, so a file that compiles, links and returns 0
// has computed the right answer. Everything else in the test suite is either a
// unit test over generated text or a call between two vcc-compiled functions,
// and neither can see a calling convention or a data layout that is wrong in a
// way both sides agree on.
//
// The procedure, and why each step exists:
//
//	vcc -S   the text backend only emits assembly, so this is the whole compiler
//	gcc -c   GNU as accepts the text and rejects what it cannot assemble
//	gcc link `common` is compiled by *gcc*, so `assert`, `add_all` and the rest
//	         come from a compiler whose ABI is known-good on this host
//	run       the exit code is the verdict: chibicc's `assert` exits 1 on a mismatch
//
// Every tool is resolved to an absolute path first, because `os.is_executable`
// does not search PATH and a bare `gcc` reads as a missing compiler. A missing
// tool is reported as BLOCKED, never as a pass or a fail.

const suite_default = 'C:/Users/MR/AppData/Local/Temp/opencode/chibicc/test'
const vcc_default = 'C:/Users/MR/Projects/vcc/fcc.exe'
const gcc_default = 'C:/Users/MR/scoop/apps/gcc/current/bin/gcc.exe'
const tcc_include = 'C:/Users/MR/Projects/v/thirdparty/tcc/include'

// verdict is one file's outcome. `blocked` is kept apart from `failed` on
// purpose: "the assembler is missing" and "the compiler computed 4 instead of 5"
// must never add up to the same number.
enum Verdict {
	ok
	failed
	blocked
}

struct Outcome {
mut:
	name      string
	verdict   Verdict
	stage     string
	detail    string
	exit_code int
}

// resolve returns an absolute path for a tool, or an empty string when there is
// none. An empty string here is the only thing that produces `blocked`.
fn resolve(name string) string {
	return os.find_abs_path_of_executable(name) or { '' }
}

// blocked builds a `blocked` outcome, which is what a missing tool produces.
//
// A missing toolchain is not a test result, and folding it into `failed` is how a
// run that measured nothing reports a clean count.
fn blocked(o Outcome, stage string, detail string) Outcome {
	mut r := o
	r.verdict = .blocked
	r.stage = stage
	r.detail = detail
	return r
}

// run executes a command and returns its exit code plus whatever it wrote.
//
// The arguments are an array rather than a string because a command string goes
// through `cmd.exe`, which eats the quoting of any path containing a space.
//
// Both streams are read. A missing toolchain error comes from the tool itself and
// arrives on stderr, and a step that fails with no message at all is the case
// where a diagnostic is worth the most, so neither stream is dropped.
fn run(exe string, args []string, dir string) (int, string) {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.set_work_folder(dir)
	p.set_redirect_stdio()
	p.run()
	p.wait()
	mut text := p.stdout_slurp()
	err := p.stderr_slurp()
	if err.trim_space() != '' {
		text = text.trim_space() + '\n' + err
	}
	return p.code, text
}

// compile_common builds `common` with gcc, once. It is the other half of every
// link in this suite, so it is built once rather than per test file.
fn compile_common(suite string, gcc string, work string) !Outcome {
	mut o := Outcome{}
	o.name = 'common'
	src := os.join_path(suite, 'common')
	if !os.exists(src) {
		return blocked(o, 'setup', 'common is missing from ${suite}')
	}
	obj := os.join_path(work, 'common.o')
	// `-x c` is required, not decorative: the file is called `common` with no
	// extension, so gcc classifies it as a linker input and produces no object at
	// all. The failure then shows up as `cannot find common.o` at the link of
	// every single test, which reads as eighteen unrelated problems.
	code, out := run(gcc, ['-x', 'c', '-c', src, '-o', obj], work)
	if code != 0 {
		return blocked(o, 'gcc -c common', out)
	}
	o.verdict = .ok
	return o
}

// one runs a single test file through the whole procedure.
fn one(suite string, vcc string, gcc string, work string, common_obj string, name string) Outcome {
	mut o := Outcome{}
	o.name = name
	src := os.join_path(suite, name)
	base := name.all_before_last('.')
	asm_path := os.join_path(work, base + '.s')
	obj := os.join_path(work, base + '.o')
	exe := os.join_path(work, base + '.exe')

	// The three include directories are the suite's own (for `test.h`), the
	// chibicc include tree, and tcc's. The first two carry the headers the tests
	// ask for by name and the third supplies the standard library, because vcc has
	// no headers of its own.
	//
	// The compiler is run from the chibicc *root* with a relative `test/<name>` path,
	// which is how chibicc's own Makefile invokes it, and which is what `__FILE__`
	// then spells. With an absolute source path the compiler answers with an absolute
	// `__FILE__`, and macro.c 340/343/397 fail on a path shape rather than on a defect.
	mut out := ''
	mut code := 0
	suite_root := os.dir(os.real_path(suite))
	src_spelling := 'test/' + name
	code, out = run(vcc, [
		'-I',
		suite,
		'-I',
		os.join_path(os.dir(suite), 'include'),
		'-I',
		tcc_include,
		'-S',
		'-o',
		asm_path,
		src_spelling,
	], suite_root)
	if code != 0 {
		o.verdict = .failed
		o.stage = 'vcc -S'
		o.detail = first_line(out)
		return o
	}

	code, out = run(gcc, ['-c', asm_path, '-o', obj], work)
	if code != 0 {
		o.verdict = .failed
		o.stage = 'gcc -c'
		o.detail = first_line(out)
		return o
	}

	code, out = run(gcc, ['-pthread', obj, common_obj, '-o', exe], work)
	if code != 0 {
		o.verdict = .failed
		o.stage = 'gcc link'
		o.detail = first_line(out)
		return o
	}

	code, out = run(exe, [], work)
	o.exit_code = code
	if code != 0 {
		o.verdict = .failed
		o.stage = 'run'
		o.detail = first_line(out)
		return o
	}
	o.verdict = .ok
	return o
}

fn first_line(text string) string {
	t := text.trim_space()
	if t.len == 0 {
		return '(no output)'
	}
	mut lines := t.split('\n')
	mut keep := []string{}
	for l in lines {
		keep << l.trim_space()
		if keep.len == 5 {
			break
		}
	}
	return keep.join(' | ')
}

fn main() {
	mut rest := os.args[1..].clone()
	mut suite := suite_default
	mut vcc := vcc_default
	mut gcc := gcc_default
	if rest.len > 0 {
		suite = rest[0]
		rest = rest[1..]
	}
	if rest.len > 0 {
		vcc = rest[0]
		rest = rest[1..]
	}
	if rest.len > 0 {
		gcc = rest[0]
	}

	vcc = resolve(vcc)
	gcc = resolve(gcc)

	mut work := os.join_path(os.temp_dir(), 'vcc_suite')
	os.mkdir_all(work) or { panic('cannot create ${work}') }

	if gcc == '' {
		println('BLOCKED all: no gcc on PATH, so nothing can be assembled or linked')
		return
	}
	if vcc == '' {
		println('BLOCKED all: no vcc at the given path, so nothing can be compiled')
		return
	}

	common := compile_common(suite, gcc, work) or { return }
	if common.verdict == .blocked {
		println('BLOCKED all: ${common.stage}: ${common.detail}')
		return
	}
	common_obj := os.join_path(work, 'common.o')

	names := test_files(suite)
	mut results := []Outcome{}
	for name in names {
		results << one(suite, vcc, gcc, work, common_obj, name)
	}

	mut n_ok := 0
	mut n_failed := 0
	mut n_blocked := 0
	for r in results {
		match r.verdict {
			.ok {
				n_ok++
				println('  PASS    ${r.name}')
			}
			.failed {
				n_failed++
				println('  FAIL    ${r.name} [${r.stage}] exit=${r.exit_code} ${r.detail}')
			}
			.blocked {
				n_blocked++
				println('  BLOCKED ${r.name} [${r.stage}] ${r.detail}')
			}
		}
	}
	println('pass=${n_ok} fail=${n_failed} blocked=${n_blocked} of ${names.len}')
}

// test_files lists the suite's own `.c` files. `common` and `driver.sh` are
// excluded: the first is the shared library, not a test, and the second is not C.
fn test_files(suite string) []string {
	mut out := []string{}
	entries := os.ls(suite) or { return out }
	mut names := entries.filter(it.ends_with('.c') && it != 'common')
	names.sort()
	for n in names {
		out << n
	}
	return out
}
