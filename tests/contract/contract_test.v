module contract

import os

// This suite asserts that the V compiler still requires everything
// `docs/CONTRACT.md` claims it requires.
//
// The contract is written against a checkout of vlang/v. If V's driver changes —
// renames a flag, drops a backtrace call, moves a symbol — these tests fail, and
// the fix is to re-read V's source and update `docs/CONTRACT.md`. Without them the
// contract silently rots, and a contract that has rotted cannot be used to judge
// whether vcc is a drop-in replacement.
//
// The whole suite is skipped, rather than failed, when the checkout is absent: a
// user evaluating vcc does not need a copy of the V compiler to run its own tests.

const driver_rel = 'vlib/v/driver/driver.v'

// find_checkout locates a vlang/v tree. VCC_V_ROOT overrides the search so the
// suite can be run against any checkout rather than a hard-coded path.
fn find_checkout() ?string {
	mut candidates := []string{}
	if env := os.getenv_opt('VCC_V_ROOT') {
		candidates << env
	}
	candidates << 'C:/Users/MMR/v'
	candidates << '../v'
	candidates << '../../v'
	for c in candidates {
		if os.is_file(os.join_path(c, driver_rel)) {
			return c
		}
	}
	return none
}

// source returns driver.v's text. A missing checkout is reported on stderr and
// reported as skipped by returning an empty string, so the caller sees a loud
// skip rather than a quiet pass or a spurious failure.
fn source() string {
	root := find_checkout() or {
		eprintln('skip: no vlang/v checkout found; set VCC_V_ROOT to run the contract suite')
		return ''
	}
	path := os.join_path(root, driver_rel)
	text := os.read_file(path) or {
		eprintln('skip: could not read ${path}')
		return ''
	}
	return text
}

// skipped reports whether source() found nothing, so each test can bail out
// without turning an absent checkout into a failure.
fn skipped(src string) bool {
	return src.len == 0
}

fn test_tcc_is_still_the_default_backend() {
	src := source()
	if skipped(src) {
		return
	}
	// The bundled tcc is selected implicitly on Windows. If that changes, vcc's
	// premise changes.
	assert src.contains('tcc.exe')
	assert src.contains('v3_default_tcc_compiler')
}

fn test_backtrace_flag_is_still_passed() {
	src := source()
	if skipped(src) {
		return
	}
	assert src.contains('-bt25'), 'CONTRACT.md §2 lists -bt25; V no longer passes it'
}

fn test_compile_only_and_shared_are_still_passed() {
	src := source()
	if skipped(src) {
		return
	}
	assert src.contains("'-c'"), 'CONTRACT.md §2 lists -c'
	assert src.contains("'-shared'"), 'CONTRACT.md §2 lists -shared'
}

fn test_resource_flags_are_still_passed() {
	src := source()
	if skipped(src) {
		return
	}
	// -B, -I and -L all come from v3_tcc_resource_flags.
	assert src.contains('base_arg:')
	assert src.contains('-B\${base_dir}')
	assert src.contains('-I\${include_dir}')
	assert src.contains('-L\${install_dir}')
}

fn test_subsystem_flags_are_still_passed() {
	src := source()
	if skipped(src) {
		return
	}
	assert src.contains("'-municode'")
	assert src.contains("'-mconsole'")
	assert src.contains("'-mwindows'")
	assert src.contains('-Wl,--stack=')
}

fn test_gnu11_is_still_the_dialect() {
	src := source()
	if skipped(src) {
		return
	}
	assert src.contains('-std=gnu11'), 'CONTRACT.md §2 lists -std=gnu11'
}

fn test_object_output_is_still_requested() {
	src := source()
	if skipped(src) {
		return
	}
	// `-c` must still be reachable, or vcc would only ever need to link and the
	// object writer could be dropped from the plan.
	assert src.contains('is_o')
}

fn test_libm_is_still_gated_on_a_prebuilt_object() {
	src := source()
	if skipped(src) {
		return
	}
	// v3_system_tcc_runtime_available checks for this exact file.
	assert src.contains('openlibm.o'), 'CONTRACT.md §6 lists openlibm.o'
}

fn test_tcc_is_still_identified_by_name() {
	src := source()
	if skipped(src) {
		return
	}
	// vcc must be recognised as a tcc-family compiler, or V's fallback logic will
	// misclassify its diagnostics.
	assert src.contains("'tcc', 'tinyc'")
	assert src.contains("starts_with('tcc:')")
}

fn test_compiler_identity_is_still_hashed() {
	src := source()
	if skipped(src) {
		return
	}
	// The object cache is keyed by compiler identity, so vcc must participate in
	// it rather than being excluded.
	assert src.contains('tcc_compiler_identity')
}

fn test_the_only_tcc_runtime_symbol_is_tcc_backtrace() {
	root := find_checkout() or { return }
	text_ok := root.len > 0
	if !text_ok {
		return
	}
	mut found := []string{}
	for f in [
		'vlib/builtin/backtraces_windows.c.v',
		'vlib/builtin/backtraces_nix.c.v',
		'vlib/builtin/panicing.c.v',
		'vlib/builtin/cfns.c.v',
	] {
		text := os.read_file(os.join_path(root, f)) or { '' }
		for line in text.split_into_lines() {
			if line.starts_with('fn C.tcc_') {
				found << line.trim_space()
			}
		}
	}
	// One symbol, not a library surface. If a second appears, phase 4 grows.
	assert found.len > 0, 'expected V to declare at least one tcc runtime symbol'
	for line in found {
		assert line.contains('tcc_backtrace'), 'unexpected TCC runtime symbol: ${line}'
	}
}

fn test_v_still_emits_gnu_attribute_constructs() {
	root := find_checkout() or { return }
	text_ok := root.len > 0
	if !text_ok {
		return
	}
	mut text := ''
	for f in ['vlib/v/gen/c/fn.v', 'vlib/v/gen/c/interface.v'] {
		text += os.read_file(os.join_path(root, f)) or { '' }
	}
	// CONTRACT.md §4. These are the constructs a plain C11 compiler would reject.
	for needed in [
		'__attribute__((constructor))',
		'__attribute__((destructor))',
		'__attribute__((naked))',
		'__attribute__((noinline))',
		'visibility("hidden")',
	] {
		assert text.contains(needed), 'CONTRACT.md §4 lists ${needed}; V no longer emits it'
	}
}
