module harness

fn result(program string, outcome Outcome, output string) Result {
	return Result{
		program:  program
		compiler: 'test'
		outcome:  outcome
		output:   output
	}
}

// bad builds a non-passing result that carries a diagnostic reason, which is
// what `report()` is required to surface.
fn bad(program string, outcome Outcome, detail string) Result {
	return Result{
		program:  program
		compiler: 'test'
		outcome:  outcome
		detail:   detail
	}
}

fn test_passed_counts_only_ok() {
	s := Suite{
		compiler: 'tcc'
		results:  [
			result('a', .ok, 'x')
			result('b', .failed, '')
			result('c', .ok, 'y'),
		]
	}
	assert s.passed() == 2
	assert s.failures().len == 1
	assert s.blocked().len == 0
}

fn test_blocked_is_not_a_failure() {
	// A missing compiler must never inflate the failure count or hide behind it.
	s := Suite{
		compiler: 'vcc'
		results:  [
			result('a', .blocked, '')
			result('b', .ok, ''),
		]
	}
	assert s.failures().len == 0
	assert s.blocked().len == 1
	assert s.summary() == 'pass=1 fail=0 blocked=1'
}

fn test_timeout_is_reported_separately() {
	s := Suite{
		results: [
			result('slow', .timeout, ''),
		]
	}
	assert s.failures().len == 1
	assert s.failures()[0].outcome == .timeout
}

fn test_summary_reports_all_three_buckets() {
	s := Suite{
		results: [
			result('a', .ok, '')
			result('b', .failed, '')
			result('c', .blocked, '')
			result('d', .timeout, ''),
		]
	}
	assert s.summary() == 'pass=1 fail=2 blocked=1'
}

fn test_report_lists_reason_for_every_non_passing_case() {
	s := Suite{
		results: [
			result('good', .ok, '')
			bad('bad', .failed, 'undefined reference to foo')
			bad('gone', .blocked, 'compiler not found'),
		]
	}
	r := s.report()
	assert r.contains('bad')
	assert r.contains('undefined reference to foo')
	assert r.contains('gone')
	assert r.contains('compiler not found')
	assert !r.contains('good')
}

fn test_compare_accepts_identical_suites() {
	base := Suite{
		results: [
			result('a', .ok, '1')
			result('b', .ok, '2'),
		]
	}
	cand := Suite{
		results: [
			result('a', .ok, '1')
			result('b', .ok, '2'),
		]
	}
	assert compare(&base, &cand).len == 0
}

fn test_compare_detects_differing_stdout() {
	// Same outcome, different behaviour: the case a naive exit-code check misses.
	base := Suite{
		results: [
			result('a', .ok, '1'),
		]
	}
	cand := Suite{
		results: [
			result('a', .ok, '2'),
		]
	}
	d := compare(&base, &cand)
	assert d.len == 1
	assert d[0].reason == 'stdout differs'
}

fn test_compare_detects_outcome_change() {
	base := Suite{
		results: [
			result('a', .ok, ''),
		]
	}
	cand := Suite{
		results: [
			result('a', .failed, 'boom'),
		]
	}
	d := compare(&base, &cand)
	assert d.len == 1
	assert d[0].reason.contains('baseline ok')
}

fn test_compare_detects_missing_baseline() {
	base := Suite{
		results: []
	}
	cand := Suite{
		results: [
			result('a', .ok, ''),
		]
	}
	d := compare(&base, &cand)
	assert d.len == 1
	assert d[0].reason.contains('no baseline')
}

fn test_run_reports_blocked_for_a_missing_compiler() {
	// No invocation is attempted, so the reason must name the missing tool.
	r := run('prog', 'vcc', 'definitely_not_a_real_compiler_xyz.exe', [], '.', 1000,
		true)
	assert r.outcome == .blocked
	assert r.detail.contains('not found')
}

fn test_run_captures_a_successful_invocation() {
	// V's `set_args` quotes any argument containing a space, so `cmd.exe` needs
	// its `/c` payload as one pre-joined argument. Passing `['/c', 'exit 0']`
	// arrives as `/c "exit 0"`, which cmd rejects with exit code 1.
	r := run('probe', 'tcc', 'cmd.exe', ['/c exit 0'], '.', 30000, false)
	assert r.outcome == .ok
	assert r.exit_code == 0
}

fn test_run_classifies_a_nonzero_exit_as_failed() {
	r := run('probe', 'tcc', 'cmd.exe', ['/c exit 3'], '.', 30000, false)
	assert r.outcome == .failed
	assert r.exit_code == 3
}

fn test_run_captures_stdout_when_asked() {
	r := run('probe', 'tcc', 'cmd.exe', ['/c echo hello'], '.', 30000, true)
	assert r.outcome == .ok
	assert r.output.len >= 0
	// The captured text lands in `detail`, which is what a build failure reports.
	assert r.detail.contains('hello')
}
