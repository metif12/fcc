module ext

import os
import src.core

// Tests for run/test/watch helpers: arg splitting, file snapshotting and
// config parsing. Compilation and execution are exercised manually (they
// need gcc + a V tree); the logic that decides *what* to run is pinned here.

fn test_split_run_args_separates_flags_inputs_and_prog() {
	o := split_run_args(['-I', 'inc', '-DDEBUG', 'a.c', 'b.bf', '--', '--verbose'])
	assert o.includes == ['inc']
	assert o.defines == ['DEBUG']
	assert o.inputs == ['a.c', 'b.bf']
	assert o.prog_args == ['--verbose']
}

fn test_split_run_args_joined_flags() {
	o := split_run_args(['-Iinc', '-DDEBUG=1', '-Bbogus', 'main.c'])
	assert o.includes == ['inc']
	assert o.defines == ['DEBUG=1']
	assert o.resource == 'bogus'
	assert o.inputs == ['main.c']
	assert o.prog_args == []string{}
}

fn test_split_run_args_no_inputs() {
	o := split_run_args([]string{})
	assert o.inputs == []string{}
	assert o.prog_args == []string{}
}

fn test_snapshots_detect_changes() {
	dir := os.join_path(os.temp_dir(), 'fcc_watch_test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	defer {
		os.rmdir_all(dir) or {}
	}
	a := os.join_path(dir, 'a.c')
	b := os.join_path(dir, 'sub')
	os.mkdir_all(b) or { panic(err.msg()) }
	c := os.join_path(b, 'c.h')
	os.write_file(a, 'int x;') or { panic(err.msg()) }
	os.write_file(c, 'int y;') or { panic(err.msg()) }
	mut first := map[string]i64{}
	collect_files([dir], ['.c', '.h'], ['.git'], mut first)
	assert first.len == 2
	// Identical tree: no change.
	mut same := map[string]i64{}
	collect_files([dir], ['.c', '.h'], ['.git'], mut same)
	assert !snapshots_differ(first, same)
	// New file: change.
	os.write_file(os.join_path(dir, 'new.c'), 'int z;') or { panic(err.msg()) }
	mut added := map[string]i64{}
	collect_files([dir], ['.c', '.h'], ['.git'], mut added)
	assert snapshots_differ(first, added)
	// Touched file: change. Untracked extension: ignored.
	os.utime(a, 1000000, 1000000) or { panic(err.msg()) }
	os.write_file(os.join_path(dir, 'notes.txt'), 'x') or { panic(err.msg()) }
	mut touched := map[string]i64{}
	collect_files([dir], ['.c', '.h'], ['.git'], mut touched)
	assert snapshots_differ(added, touched)
	assert touched.len == 3
}

fn test_is_test_file_names() {
	assert is_test_file('sum_test.c')
	assert is_test_file('test_sum.c')
	assert is_test_file('TEST_X_TEST.C')
	assert !is_test_file('main.c')
	assert !is_test_file('helper.c')
	assert !is_test_file('sum_test.h')
}

fn test_discover_test_files_sorted() {
	dir := os.join_path(os.temp_dir(), 'fcc_discover_test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'z_test.c'), '') or { panic(err.msg()) }
	os.write_file(os.join_path(dir, 'a_test.c'), '') or { panic(err.msg()) }
	os.write_file(os.join_path(dir, 'main.c'), '') or { panic(err.msg()) }
	found := discover_test_files(dir)
	assert found.len == 2
	assert found[0].ends_with('a_test.c')
	assert found[1].ends_with('z_test.c')
}

fn test_default_watch_extensions_cover_inputs() {
	core.reset_registries()
	exts := default_watch_extensions()
	assert '.blip' in exts
	assert '.toml' in exts
}
