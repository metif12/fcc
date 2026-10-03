module harness

import os
import time

// Outcome classifies one program in the differential suite.
pub enum Outcome {
	ok
	failed
	timeout
	// The compiler could not be invoked at all. This is an environment problem
	// and must never be silently counted as a test result.
	blocked
}

// Result is the measured behaviour of one program under one compiler.
pub struct Result {
pub mut:
	program    string
	compiler   string
	outcome    Outcome
	detail     string
	exit_code  int
	elapsed_ms int
	// stdout of the built program, for behavioural comparison between compilers
	output string
}

// Suite is the full set of measurements from one run.
pub struct Suite {
pub mut:
	compiler string
	results  []Result
}

// failures returns the results that are not `ok`, excluding `blocked` ones so a
// missing toolchain cannot masquerade as a regression.
pub fn (s &Suite) failures() []Result {
	return s.results.filter(it.outcome == .failed || it.outcome == .timeout)
}

// blocked returns results that could not be measured at all.
pub fn (s &Suite) blocked() []Result {
	return s.results.filter(it.outcome == .blocked)
}

pub fn (s &Suite) passed() int {
	return s.results.filter(it.outcome == .ok).len
}

// summary renders the pass/fail/blocked split. It is deliberately explicit about
// `blocked` rather than omitting it, because a run that skipped cases and
// reported a clean count is worse than no run at all.
pub fn (s &Suite) summary() string {
	return 'pass=${s.passed()} fail=${s.failures().len} blocked=${s.blocked().len}'
}

// report renders every non-passing result with its reason attached.
pub fn (s &Suite) report() string {
	mut b := []string{}
	for r in s.results {
		if r.outcome == .ok {
			continue
		}
		b << '  ${r.outcome} ${r.program} [${r.compiler}] ${r.detail}'
	}
	return (b.join('\n') + '\n' + s.summary()).trim_space()
}

// Divergence is a behavioural difference between two compilers on one program.
pub struct Divergence {
pub:
	program string
	reason  string
}

// compare walks two suites over the same program list and returns the cases where
// the compilers disagreed. Equal outcomes with equal output means the two
// compilers are interchangeable for that program.
pub fn compare(baseline &Suite, candidate &Suite) []Divergence {
	mut by_program := map[string]Result{}
	for r in baseline.results {
		by_program[r.program] = r
	}
	mut out := []Divergence{}
	for r in candidate.results {
		base := by_program[r.program] or {
			out << Divergence{
				program: r.program
				reason:  'no baseline result for this program'
			}
			continue
		}
		if base.outcome != r.outcome {
			out << Divergence{
				program: r.program
				reason:  'baseline ${base.outcome} but candidate ${r.outcome}: ${r.detail}'
			}
			continue
		}
		if base.outcome == .ok && base.output != r.output {
			out << Divergence{
				program: r.program
				reason:  'stdout differs'
			}
		}
	}
	return out
}

// run invokes `cmd` with `args` inside `dir` and classifies the result.
//
// A missing executable is `blocked`, not `failed`. A run that outlives
// `timeout_ms` is killed and recorded as `timeout`, never as a silent pass.
// `capture_output` distinguishes a build step, whose diagnostics matter, from a
// program run, whose stdout is the thing under comparison.
pub fn run(program string, compiler string, cmd string, args []string, dir string,
	timeout_ms int, capture_output bool) Result {
	mut r := Result{
		program:   program
		compiler:  compiler
		exit_code: -1
	}
	// `os.is_executable` does not search PATH, so a bare `tcc` would be reported
	// as a missing compiler. Resolve first, and only then test executability.
	cmd_path := os.find_abs_path_of_executable(cmd) or { cmd }
	if !os.is_executable(cmd_path) {
		r.outcome = .blocked
		r.detail = 'compiler not found or not executable: ${cmd}'
		return r
	}
	mut p := os.new_process(cmd_path)
	p.set_args(args)
	p.set_work_folder(dir)
	if capture_output {
		p.set_redirect_stdio()
	}
	mut sw := time.new_stopwatch()
	p.run()
	// `p.status` only advances when something polls or waits, so the loop below
	// must use `is_alive()`, not `p.status`, to notice the child has finished.
	// A run that outlives `timeout_ms` is killed and recorded as `timeout`.
	for p.is_alive() {
		if int(sw.elapsed().milliseconds()) >= timeout_ms {
			p.signal_kill()
			break
		}
		time.sleep(10 * time.millisecond)
	}
	r.elapsed_ms = int(sw.elapsed().milliseconds())
	p.wait()
	if r.elapsed_ms >= timeout_ms && r.exit_code_unknown() {
		r.outcome = .timeout
		r.detail = 'exceeded ${timeout_ms}ms'
		return r
	}
	r.exit_code = p.code
	if capture_output {
		r.detail = p.stdout_slurp().trim_space()
	}
	match p.status {
		.exited {
			r.outcome = if p.code == 0 { .ok } else { .failed }
		}
		else {
			r.outcome = .failed
			if r.detail == '' {
				r.detail = 'process ended with status ${p.status}'
			}
		}
	}
	return r
}

// exit_code_unknown reports whether the exit code carries any information. V
// leaves it at -1 for a process it killed, which is how a timeout is told apart
// from a program that genuinely exited with a non-zero code.
fn (r &Result) exit_code_unknown() bool {
	return r.exit_code < 0
}
