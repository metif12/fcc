module main

import os

// Run one chibicc suite file through the whole procedure and print ALL of its output.
//
// `suite.v` reports five trimmed lines per file, which is enough for a pass/fail count
// and useless for locating a failure: the suite's `assert` prints one line per *passing*
// assertion and a differently-shaped line for the failing one, so the last line printed
// is not the failure — it is the last *pass* before it. This exists to answer "which
// assertion failed", which is the first question for anything that goes red.
//
// The procedure is suite.v's, byte for byte, because the verdict has to mean the same
// thing: vcc assembles, gcc assembles that, gcc links `common` (compiled by *gcc*, so
// `assert` and `printf` come from a compiler whose ABI is known good), and the exit code
// is the result.

const suite_default = 'C:/Users/MR/AppData/Local/Temp/opencode/chibicc/test'
const vcc_default = 'C:/Users/MR/Projects/vcc/fcc.exe'
const gcc_default = 'C:/Users/MR/scoop/apps/gcc/current/bin/gcc.exe'
const tcc_include = 'C:/Users/MR/Projects/v/thirdparty/tcc/include'
const work_default = 'C:/Users/MR/AppData/Local/Temp/opencode/va-probe/onefile'

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

fn main() {
	mut rest := os.args[1..].clone()
	if rest.len == 0 {
		eprintln('usage: v run tools/onefile.v <name.c>')
		exit(2)
	}
	name := rest[0]
	rest = rest[1..].clone()
	suite := if rest.len > 0 { rest[0] } else { suite_default }
	vcc := if rest.len > 1 { rest[1] } else { vcc_default }
	gcc := if rest.len > 2 { rest[2] } else { gcc_default }

	work := work_default
	os.mkdir_all(work) or { panic('cannot create ${work}') }
	src := os.join_path(suite, name)
	if !os.exists(src) {
		eprintln('no such file: ${src}')
		exit(2)
	}

	common_obj := os.join_path(work, 'common.o')
	if !os.exists(common_obj) {
		code, out := run(gcc, ['-x', 'c', '-c', os.join_path(suite, 'common'), '-o', common_obj],
			work)
		if code != 0 {
			eprintln('common failed: ${out}')
			exit(1)
		}
	}

	base := name.all_before_last('.')
	asm_path := os.join_path(work, base + '.s')
	obj := os.join_path(work, base + '.o')
	exe := os.join_path(work, base + '.exe')

	// `mut`, because the same two names are bound three times below — suite.v does the
	// same thing for the same reason.
	//
	// The compiler is run from the chibicc *root* with a relative `test/<name>` path,
	// which is how chibicc's own Makefile:17 invokes it, and it is the only way
	// `__FILE__` produces `test/macro.c` — the spelling the tests assert on. With an
	// absolute source path the compiler correctly answers with an absolute
	// `__FILE__`, and macro.c 340/343/397 then fail on a path shape rather than on a
	// defect. The `-I` list stays absolute, because nothing asserts on those.
	suite_root := os.dir(os.real_path(suite))
	src_spelling := 'test/' + name
	mut code := 0
	mut out := ''
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
		println('STAGE vcc -S failed (exit ${code})')
		println(out)
		exit(1)
	}

	code, out = run(gcc, ['-c', asm_path, '-o', obj], work)
	if code != 0 {
		println('STAGE gcc -c failed (exit ${code})')
		println(out)
		exit(1)
	}

	code, out = run(gcc, ['-pthread', obj, common_obj, '-o', exe], work)
	if code != 0 {
		println('STAGE gcc link failed (exit ${code})')
		println(out)
		exit(1)
	}

	code, out = run(exe, [], work)
	println('RUN exit=${code}')
	println(out)
	// The exit code is the verdict, so it is propagated: a caller that checks
	// $LASTEXITCODE sees what the run saw.
	exit(if code == 0 { 0 } else { 1 })
}
