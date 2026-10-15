import os

// cmp_c compares vcc against tcc on the programs in `tests/endtoend/`.
//
// It is the counterpart to `tools/suite/suite.v`, and the difference is which programs get
// compiled: the suite runs chibicc's tests, this runs the project's own probes. Same
// three steps, same match/differ/blocked split, same reason — a calling convention or a
// data layout that is wrong in a way two vcc-compiled functions agree on is invisible to
// any test that never leaves the compiler.
//
// The vcc path is `vcc -S`, then `gcc -o` to link that assembly with nothing else, so
// every program has to have its own `main`. The tcc path is one `tcc -o`.
//
// vcc is never used to link: it cannot emit an object yet (phase 3), and a program that
// vcc compiled and gcc linked is exactly the cross-boundary test this project exists to
// run — the ABI is only observable where the two sides differ.
//
// Every program is classified. A program tcc itself refuses is BLOCKED rather than
// failed, because that is a statement about the probe and not about vcc.
//
// Artifacts land in a scratch directory outside the tree, and the sources are read from
// the tree, so adding a program to `tests/endtoend/` is enough to have it compared.
//
// The scratch directory is named rather than derived from `os.temp_dir()`, which on this
// host is where every V build on the machine puts its own `v_<uid>`. It has to be set:
// an empty value would make `join_path('', 'cmp')` a *relative* `cmp`, and the runner
// would quietly create it in whatever directory it was started from — which is how the
// first version of this tool came to leave its output under `tools/probe/`.
fn main() {
	scratch := os.getenv('VCC_PROBE_DIR')
	assert scratch != '', 'VCC_PROBE_DIR must name a directory to write artifacts into'
	probe_dir := os.join_path(scratch, 'cmp')

	// Relative to this file rather than the caller's directory: the tools and the
	// programs they run are two different trees, and only one of them is the caller's cwd.
	root := os.dir(os.dir(os.dir(os.args[0])))
	src_dir := os.join_path(root, 'tests', 'endtoend')

	vcc := os.join_path(root, 'fcc.exe')
	v_root := os.getenv('VCC_V_ROOT')
	assert v_root != '', 'VCC_V_ROOT must name the V tree tcc and gcc are taken from'
	gcc := os.join_path(os.dir(os.dir(v_root)), 'scoop', 'apps', 'gcc', 'current', 'bin',
		'gcc.exe')
	tcc := os.join_path(v_root, 'thirdparty', 'tcc', 'tcc.exe')

	// tcc has a builtin include path; vcc does not, and `-I` is how the real driver
	// supplies it. Passing the same directory to both is what makes the two runs
	// comparable at all — otherwise vcc fails on `#include <stdio.h>` and the probe
	// measures the include path rather than the compiler.
	tcc_include := os.join_path(v_root, 'thirdparty', 'tcc', 'include')

	os.mkdir_all(probe_dir) or { panic('cannot create ${probe_dir}') }

	names := os.ls(src_dir)!.filter(it.ends_with('.c')).sorted()
	if names.len == 0 {
		panic('no programs in ${src_dir}')
	}

	// `match` is a V keyword, so the counter is not called that.
	mut same := 0
	mut differ := 0
	mut blocked := 0
	for name in names {
		src := os.join_path(src_dir, name)
		base := name.all_before_last('.')

		// The oracle is tcc when tcc will take the program, and gcc when it will not.
		//
		// tcc is the primary because it is the compiler vcc has to agree with on this
		// host — same headers, same objects, same C library. But tcc predates C23 and
		// rejects `__VA_OPT__` outright, and it reads a pp-number used as a macro
		// argument as an invalid number rather than as one token. Falling back to gcc
		// keeps those shapes measurable rather than BLOCKED; which oracle answered is
		// printed, so a MATCH is never ambiguous about what it was measured against.
		//
		// A program *both* refuse is still BLOCKED, because that is a statement about
		// the program and not about vcc.
		mut oracle_name := 'tcc'
		mut oracle_exe := os.join_path(probe_dir, base + '_cmp_tcc.exe')
		if os.exec([tcc, '-I', tcc_include, '-o', oracle_exe, src]).exit_code != 0 {
			oracle_name = 'gcc'
			oracle_exe = os.join_path(probe_dir, base + '_cmp_gcc.exe')
			if os.exec([gcc, '-o', oracle_exe, src]).exit_code != 0 {
				println('BLOCKED ${name}: tcc and gcc both refused it')
				blocked++
				continue
			}
		}

		// A tcc binary that *links* is not yet an oracle that answers. tcc reaches
		// for `__chkstk` on any frame over a page, the same requirement fcc had to
		// learn, and on this host that symbol is not linked into a standalone exe —
		// so the binary builds and then dies with an NTSTATUS before printing
		// anything. That is a statement about the oracle, not about fcc, and gcc
		// answers the same question without the dependency.
		//
		// It is gated on the oracle having produced nothing, so a program that
		// crashes the oracle *after* printing is still reported as it stands: that
		// is a real difference and must not be swept up. And the comparison still
		// happens, against gcc, so a defect in fcc shows up exactly as before.
		if oracle_name == 'tcc' {
			mut probe := os.exec([oracle_exe])
			if probe.output.trim_space() == '' && probe.exit_code != 0 {
				oracle_name = 'gcc'
				oracle_exe = os.join_path(probe_dir, base + '_cmp_gcc.exe')
				if os.exec([gcc, '-o', oracle_exe, src]).exit_code != 0 {
					println('BLOCKED ${name}: tcc cannot run it and gcc refused it')
					blocked++
					continue
				}
			}
		}

		s_path := os.join_path(probe_dir, base + '_cmp_vcc.s')
		vcc_exe := os.join_path(probe_dir, base + '_cmp_fcc.exe')
		mut rc := os.exec([vcc, '-I', tcc_include, '-S', '-o', s_path, src])
		if rc.exit_code != 0 {
			println('FAIL    ${name}: vcc -S exited ${rc.exit_code}')
			differ++
			continue
		}
		rc = os.exec([gcc, '-o', vcc_exe, s_path])
		if rc.exit_code != 0 {
			println('FAIL    ${name}: linking vcc output exited ${rc.exit_code}')
			differ++
			continue
		}

		a := os.exec([oracle_exe])
		b := os.exec([vcc_exe])
		// stdout *and* the exit code, because a program that prints the right thing and
		// then crashes is not a pass.
		if a.output.trim_space() == b.output.trim_space() && a.exit_code == b.exit_code {
			println('MATCH   ${name}  (${oracle_name})')
			same++
		} else {
			println('DIFFER  ${name}  (${oracle_name} exit=${a.exit_code} vcc exit=${b.exit_code})')
			differ++
		}
	}
	println('match=${same} differ=${differ} blocked=${blocked} of ${names.len}')
}
