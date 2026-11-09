module ext

import os
import time
import src.core
import src.fcc

// Run, test and watch: the `go run` / `go test` / `air` of fcc.
//
// - `fcc run` compiles inputs (any language, one output binary) and executes
//   it, forwarding the exit code. `v run` and `go run` are the model.
// - `fcc test` runs the `test` task when the project defines one, else
//   compiles and runs every `*_test.c` / `test_*.c` in the directory (each a
//   standalone program; exit 0 passes, like `go test`).
// - `fcc watch` re-runs a command whenever watched files change (air-like),
//   driven by the `[watch]` config section.
//
// Linking needs a system linker: `gcc` on PATH (the same gcc the tools use).
// Headers resolve like the rest of fcc: `-I` flags first, then `-B
// <root>/include`, then the bundled headers under `$VCC_V_ROOT`.

// ---------- shared: compile + link ----------

// default_include_dirs returns the fallback header roots: `-B` resource root
// first, then the V tree's bundled headers. CLI `-I` paths stay ahead of
// these (first-hit-wins), so explicit flags always override the fallback.
fn default_include_dirs(resource_root string) []string {
	mut out := []string{}
	if resource_root != '' {
		p := os.join_path(resource_root, 'include')
		if os.is_dir(p) && p !in out {
			out << p
		}
	}
	vroot := os.getenv('VCC_V_ROOT')
	if vroot != '' {
		// V's own tree ships the headers under thirdparty/tcc/include.
		p := os.join_path(vroot, 'thirdparty', 'tcc', 'include')
		if os.is_dir(p) && p !in out {
			out << p
		}
	}
	return out
}

// find_linker locates the system linker driver.
fn find_linker() !string {
	for name in ['gcc', 'cc'] {
		if found := os.find_abs_path_of_executable(name) {
			return found
		}
	}
	return error('fcc: linking needs gcc (or cc) on PATH')
}

// exe_suffix is '.exe' where executables need it.
fn exe_suffix() string {
	return $if windows { '.exe' } $else { '' }
}

// compile_inputs builds every input into one object file through the plugin
// pipeline, so mixed-language inputs link into one output.
fn compile_inputs_to_obj(inputs []string, includes []string, sys_includes []string, defines []string, undefines []string, obj_path string) ! {
	mut ctx := core.PipelineContext{
		inputs:       inputs.clone()
		output:       obj_path
		std:          'gnu11'
		includes:     includes.clone()
		sys_includes: sys_includes.clone()
		defines:      defines.clone()
		undefines:    undefines.clone()
		emit:         'obj'
	}
	core.run_pipeline(mut ctx, inputs)!
	for d in ctx.diagnostics {
		eprintln(d)
	}
	if ctx.failed {
		return error('compile failed')
	}
}

// link_objects links objects into an executable.
fn link_objects(ld string, objs []string, exe string, lib_paths []string, libs []string) ! {
	mut cmd := [ld, '-o', exe]
	cmd << objs
	for p in lib_paths {
		cmd << '-L' + p
	}
	for l in libs {
		cmd << '-l' + l
	}
	r := os.execute(cmd.join(' '))
	if r.output != '' {
		print(r.output)
	}
	if r.exit_code != 0 {
		return error('link failed with exit ${r.exit_code}')
	}
}

// temp_artifact names a scratch file unique to this process and index.
fn temp_artifact(tag string, idx int, ext string) string {
	return os.join_path(os.temp_dir(), 'fcc_${tag}_${os.getpid()}_${idx}${ext}')
}

// ---------- `fcc run` ----------

struct RunOptions {
mut:
	includes     []string
	sys_includes []string
	defines      []string
	undefines    []string
	resource     string
	inputs       []string
	prog_args    []string
}

// split_run_args divides `fcc run` arguments at `--`: flags and inputs
// before it, program arguments after it.
fn split_run_args(args []string) RunOptions {
	mut o := RunOptions{}
	mut i := 0
	mut prog := false
	for i < args.len {
		a := args[i]
		if !prog && a == '--' {
			prog = true
			i++
			continue
		}
		if prog {
			o.prog_args << a
			i++
			continue
		}
		if a == '-I' && i + 1 < args.len {
			o.includes << args[i + 1]
			i += 2
			continue
		}
		if a.starts_with('-I') && a.len > 2 {
			o.includes << a[2..]
			i++
			continue
		}
		if a == '-isystem' && i + 1 < args.len {
			o.sys_includes << args[i + 1]
			i += 2
			continue
		}
		if a == '-D' && i + 1 < args.len {
			o.defines << args[i + 1]
			i += 2
			continue
		}
		if a.starts_with('-D') && a.len > 2 {
			o.defines << a[2..]
			i++
			continue
		}
		if a == '-U' && i + 1 < args.len {
			o.undefines << args[i + 1]
			i += 2
			continue
		}
		if a == '-B' && i + 1 < args.len {
			o.resource = args[i + 1]
			i += 2
			continue
		}
		if a.starts_with('-B') && a.len > 2 {
			o.resource = a[2..]
			i++
			continue
		}
		o.inputs << a
		i++
	}
	return o
}

fn cmd_run(args []string, cfg core.FccConfig) int {
	o := split_run_args(args)
	if o.inputs.len == 0 {
		eprintln('usage: fcc run [-I dir] [-D def] [-B root] file... [-- prog args...]')
		return 1
	}
	// CLI includes first (first-hit-wins), then config, then fallbacks.
	mut includes := o.includes.clone()
	includes << cfg.includes
	includes << default_include_dirs(o.resource)
	mut sys_includes := o.sys_includes.clone()
	sys_includes << cfg.sys_includes
	mut defines := o.defines.clone()
	defines << cfg.defines
	mut undefines := o.undefines.clone()
	undefines << cfg.undefines
	ld := find_linker() or {
		eprintln(err.msg())
		return 1
	}
	obj := temp_artifact('run', 0, '.o')
	exe := temp_artifact('run', 0, exe_suffix())
	defer {
		os.rm(obj) or {}
		os.rm(exe) or {}
	}
	compile_inputs_to_obj(o.inputs, includes, sys_includes, defines, undefines, obj) or {
		eprintln('fcc run: ${err.msg()}')
		return 1
	}
	link_objects(ld, [obj], exe, cfg.lib_paths, cfg.libs) or {
		eprintln('fcc run: ${err.msg()}')
		return 1
	}
	mut cmd := [exe]
	cmd << o.prog_args
	r := os.execute(cmd.join(' '))
	print(r.output)
	return r.exit_code
}

// ---------- `fcc test` ----------

struct TestResult {
mut:
	name    string
	ok      bool
	detail  string
	output  string
	elapsed i64
}

fn is_test_file(path string) bool {
	base := os.file_name(path).to_lower()
	return (base.ends_with('_test.c') || base.starts_with('test_')) && base.ends_with('.c')
}

fn discover_test_files(dir string) []string {
	entries := os.ls(dir) or { return []string{} }
	mut out := []string{}
	for e in entries {
		p := os.join_path(dir, e)
		if os.is_file(p) && is_test_file(p) {
			out << p
		}
	}
	out.sort()
	return out
}

fn run_one_test(path string, idx int, includes []string, sys_includes []string, defines []string, undefines []string, lib_paths []string, libs []string, verbose bool) TestResult {
	mut r := TestResult{
		name: path
	}
	t0 := time.ticks()
	ld := find_linker() or {
		r.ok = false
		r.detail = err.msg()
		return r
	}
	obj := temp_artifact('test', idx, '.o')
	exe := temp_artifact('test', idx, exe_suffix())
	defer {
		os.rm(obj) or {}
		os.rm(exe) or {}
	}
	compile_inputs_to_obj([path], includes, sys_includes, defines, undefines,
		obj) or {
		r.ok = false
		r.detail = 'build failed: ${err.msg()}'
		r.elapsed = time.ticks() - t0
		return r
	}
	link_objects(ld, [obj], exe, lib_paths, libs) or {
		r.ok = false
		r.detail = 'link failed: ${err.msg()}'
		r.elapsed = time.ticks() - t0
		return r
	}
	run := os.execute(exe)
	r.elapsed = time.ticks() - t0
	r.output = run.output
	if run.exit_code == 0 {
		r.ok = true
	} else {
		r.ok = false
		r.detail = 'exit ${run.exit_code}'
	}
	if verbose && run.output != '' {
		print(run.output)
	}
	return r
}

fn cmd_test(args []string, cfg core.FccConfig) int {
	// A project-defined `test` task wins over discovery.
	if 'test' in cfg.tasks {
		mut targets := args.filter(!it.starts_with('-'))
		if targets.len == 0 {
			targets = ['test']
		}
		force := '--force' in args || '-f' in args
		core.run_tasks_forced(cfg.tasks, targets, fn (run string) int {
			if run == '' {
				return 0
			}
			r := os.execute(run)
			print(r.output)
			return r.exit_code
		}, force) or {
			eprintln(err.msg())
			return 1
		}
		return 0
	}
	verbose := '-v' in args
	mut files := args.filter(!it.starts_with('-'))
	mut paths := []string{}
	if files.len == 0 {
		paths = discover_test_files('.')
		if paths.len == 0 {
			eprintln('fcc test: no test files (*_test.c, test_*.c) and no [task."test"]')
			return 1
		}
	} else {
		for f in files {
			if os.is_dir(f) {
				paths << discover_test_files(f)
			} else {
				paths << f
			}
		}
	}
	mut includes := cfg.includes.clone()
	includes << default_include_dirs('')
	mut passed := 0
	mut failed := 0
	for i, p in paths {
		r := run_one_test(p, i, includes, cfg.sys_includes, cfg.defines, cfg.undefines,
			cfg.lib_paths, cfg.libs, verbose)
		ms := r.elapsed
		if r.ok {
			passed++
			println('ok   ${r.name} (${ms}ms)')
		} else {
			failed++
			println('FAIL ${r.name} ${r.detail} (${ms}ms)')
			if !verbose && r.output != '' {
				print(r.output)
			}
		}
	}
	println('${passed} passed, ${failed} failed of ${paths.len}')
	if failed > 0 {
		return 1
	}
	return 0
}

// ---------- `fcc watch` (air-like) ----------

fn default_watch_extensions() []string {
	mut exts := []string{}
	for p in core.list_inputs() {
		for e in p.extensions() {
			if e !in exts {
				exts << e
			}
		}
	}
	for e in ['.blip', '.toml'] {
		if e !in exts {
			exts << e
		}
	}
	return exts
}

fn default_watch_ignore() []string {
	return ['.git', '.o', '.s', '.exe', '.obj']
}

// collect_files snapshots mtimes of watched files under dirs.
fn collect_files(dirs []string, exts []string, ignore []string, mut out map[string]i64) {
	for d in dirs {
		entries := os.ls(d) or { continue }
		for e in entries {
			p := os.join_path(d, e)
			mut skip := false
			for ig in ignore {
				if p.contains(ig) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}
			if os.is_dir(p) {
				collect_files([p], exts, ignore, mut out)
				continue
			}
			lower := p.to_lower()
			for ext in exts {
				if lower.ends_with(ext.to_lower()) {
					out[p] = os.file_last_mod_unix(p)
					break
				}
			}
		}
	}
}

fn snapshots_differ(a map[string]i64, b map[string]i64) bool {
	if a.len != b.len {
		return true
	}
	for k, v in a {
		if k !in b || b[k] != v {
			return true
		}
	}
	return false
}

fn cmd_watch(args []string, cfg core.FccConfig) int {
	mut clear := cfg.watch.clear
	mut debounce_ms := cfg.watch.debounce_ms
	if debounce_ms <= 0 {
		debounce_ms = 300
	}
	mut cmd := []string{}
	mut i := 0
	for i < args.len {
		a := args[i]
		if a == '--clear' {
			clear = true
			i++
			continue
		}
		if a == '--debounce' && i + 1 < args.len {
			debounce_ms = args[i + 1].int()
			i += 2
			continue
		}
		if a == '--' {
			i++
			continue
		}
		cmd << a
		i++
	}
	if cmd.len == 0 {
		if cfg.watch.run != '' {
			cmd = [cfg.watch.run]
		} else {
			cmd = ['fcc', 'build']
		}
	}
	mut dirs := cfg.watch.dirs.clone()
	if dirs.len == 0 {
		dirs = ['.']
	}
	mut exts := cfg.watch.extensions.clone()
	if exts.len == 0 {
		exts = default_watch_extensions()
	}
	mut ignore := default_watch_ignore()
	ignore << cfg.watch.ignore
	mut prev := map[string]i64{}
	collect_files(dirs, exts, ignore, mut prev)
	run_watch_command(cmd, clear, true)
	for {
		time.sleep(500 * time.millisecond)
		mut cur := map[string]i64{}
		collect_files(dirs, exts, ignore, mut cur)
		if snapshots_differ(prev, cur) {
			// Debounce: wait out rapid saves, then confirm the tree settled.
			time.sleep(debounce_ms * time.millisecond)
			mut settled := map[string]i64{}
			collect_files(dirs, exts, ignore, mut settled)
			prev = settled.clone()
			run_watch_command(cmd, clear, false)
		}
	}
	return 0
}

fn run_watch_command(cmd []string, clear bool, first bool) {
	if clear {
		print('\x1b[2J\x1b[H')
	}
	if first {
		println('watch: initial run: ${cmd.join(' ')}')
	} else {
		println('watch: change detected, running: ${cmd.join(' ')}')
	}
	r := os.execute(cmd.join(' '))
	print(r.output)
	if r.exit_code != 0 {
		println('watch: command exited ${r.exit_code}')
	}
}
