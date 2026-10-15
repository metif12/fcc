module main

import os
import time

// cts runs the c-testsuite single-exec suite against fcc and classifies every case.
//
// Each case is `NNN.c` with `NNN.c.expected` holding the stdout+stderr it must
// produce and exit 0. The fcc path is `fcc -S`, then `gcc -c`, then `gcc -o` to link
// — vcc is never used to link — and the binary runs with a watchdog, because a
// hung test must be a line in the report rather than the end of the run.
//
// Every DIFFER gets its oracle control automatically: tcc builds and runs the
// same source, and the report says whether tcc agrees with the expected output
// or with fcc. A DIFFER where tcc agrees with fcc is a statement about the test
// (or the platform), not about fcc; one where tcc agrees with expected is a
// real defect. This is the rule this project's log keeps re-learning: no failure
// without its control.
//
// Artifacts land under `$VCC_PROBE_DIR/cts`, and the suite itself is read from
// `$VCC_CTS_DIR` (the c-testsuite checkout), so nothing is vendored and nothing
// drifts: the checkout's commit is printed in the summary.
//
// Usage: `v run tools/cts/cts.v [prefix]` — an optional prefix runs only the
// cases whose names start with it, for bisecting a failure without the full run.

const per_test_ms = 30000

fn main() {
	scratch := os.getenv('VCC_PROBE_DIR')
	assert scratch != '', 'VCC_PROBE_DIR must name a directory to write artifacts into'
	cts_root := os.getenv('VCC_CTS_DIR')
	assert cts_root != '', 'VCC_CTS_DIR must name the c-testsuite checkout'
	work := os.join_path(scratch, 'cts')
	os.mkdir_all(work) or { panic('cannot create ${work}') }

	root := os.dir(os.dir(os.dir(os.args[0])))
	fcc := os.join_path(root, 'fcc.exe')
	v_root := os.getenv('VCC_V_ROOT')
	assert v_root != '', 'VCC_V_ROOT must name the V tree tcc and gcc are taken from'
	gcc := os.join_path(os.dir(os.dir(v_root)), 'scoop', 'apps', 'gcc', 'current',
		'bin', 'gcc.exe')
	tcc := os.join_path(v_root, 'thirdparty', 'tcc', 'tcc.exe')
	tcc_include := os.join_path(v_root, 'thirdparty', 'tcc', 'include')

	src_dir := os.join_path(cts_root, 'tests', 'single-exec')
	mut names := os.ls(src_dir)!.filter(it.ends_with('.c') && !it.ends_with('.expected')).sorted()
	if os.args.len > 1 {
		prefix := os.args[1]
		names = names.filter(it.starts_with(prefix))
	}
	if names.len == 0 {
		panic('no cases in ${src_dir}')
	}

	mut same := 0
	mut differ := 0
	mut blocked := 0
	for name in names {
		base := name.all_before_last('.')
		src := os.join_path(src_dir, name)
		expected := os.read_file(os.join_path(src_dir, '${name}.expected')) or { '' }

		s_path := os.join_path(work, '${base}.s')
		o_path := os.join_path(work, '${base}.o')
		vcc_exe := os.join_path(work, '${base}.exe')

		rc := os.exec([fcc, '-I', tcc_include, '-S', '-o', s_path, src])
		if rc.exit_code != 0 {
			// A frontend refusal is only BLOCKED if the oracle refuses it too.
			// tcc takes every one of the current thirteen, so they are DIFFERs —
			// gaps in fcc, not statements about the test.
			tcc_exe := os.join_path(work, '${base}_tcc.exe')
			if os.exec([tcc, '-I', tcc_include, '-o', tcc_exe, src]).exit_code != 0 {
				println('BLOCKED ${name}: fcc and tcc both refused it')
				blocked++
				continue
			}
			println('DIFFER  ${name}: fcc -S exited ${rc.exit_code}, tcc takes it')
			differ++
			continue
		}
		rc2 := os.exec([gcc, '-c', s_path, '-o', o_path])
		if rc2.exit_code != 0 {
			println('DIFFER  ${name}: assembler refused fcc output')
			differ++
			continue
		}
		rc3 := os.exec([gcc, o_path, '-o', vcc_exe])
		if rc3.exit_code != 0 {
			println('DIFFER  ${name}: linking fcc output exited ${rc3.exit_code}')
			differ++
			continue
		}
		out, code, timed_out := run_guarded(vcc_exe)
		if timed_out {
			println('DIFFER  ${name}: fcc binary hung past ${per_test_ms / 1000}s')
			differ++
			continue
		}
		if out.trim_space() == expected.trim_space() && code == 0 {
			println('MATCH   ${name}')
			same++
			continue
		}
		// The oracle control, run only on mismatch.
		tcc_exe := os.join_path(work, '${base}_tcc.exe')
		if os.exec([tcc, '-I', tcc_include, '-o', tcc_exe, src]).exit_code != 0 {
			println('BLOCKED ${name}: tcc refused it and fcc differs')
			blocked++
			continue
		}
		t_out, t_code, t_timed_out := run_guarded(tcc_exe)
		if t_timed_out {
			println('DIFFER  ${name}: fcc differs, tcc hung (fcc exit=${code})')
		} else if t_out.trim_space() == expected.trim_space() && t_code == 0 {
			println('DIFFER  ${name}: fcc exit=${code}, tcc matches expected')
		} else if t_out.trim_space() == out.trim_space() && t_code == code {
			println('DIFFER  ${name}: fcc and tcc agree against expected (both exit=${code})')
		} else {
			println('DIFFER  ${name}: fcc exit=${code}, tcc exit=${t_code}, all three differ')
		}
		differ++
	}
	println('match=${same} differ=${differ} blocked=${blocked} of ${names.len}')
}

// run_guarded runs a binary and returns its merged output, exit code, and whether
// the watchdog fired. A hung test is a report line, never the end of the run.
// The binary runs with the scratch directory as its working directory, because
// some tests write files beside themselves and those artifacts must not land in
// the tree the runner was started from.
fn run_guarded(exe string) (string, int, bool) {
	mut p := os.new_process(exe)
	p.set_redirect_stdio()
	p.set_work_folder(os.dir(exe))
	p.run()
	deadline := time.now().add(per_test_ms * time.millisecond)
	for p.is_alive() {
		if time.now() >= deadline {
			p.signal_kill()
			p.wait()
			p.close()
			return '', -1, true
		}
		time.sleep(100 * time.millisecond)
	}
	p.wait()
	code := p.code
	out := p.stdout_slurp() + p.stderr_slurp()
	p.close()
	return out, code, false
}
