module core

import os

// Task runner shared by `fcc build`, build.blip and build.v.
//
// build.blip is declarative and runs in-process:
//   task "build" {
//     inputs = ["main.c"]
//     run = "compile --emit obj"
//     depends = ["gen"]
//   }
//
// build.v is programmatic (like build.zig): a V program importing the
// builder API. `fcc build` delegates to `v run build.v` when build.v
// exists and no build.blip task was requested, so build logic stays
// real code instead of a second DSL.

pub fn find_build_file(dir string) string {
	for name in ['build.blip', 'build.toml', 'build.v'] {
		p := os.join_path(dir, name)
		if os.is_file(p) {
			return p
		}
	}
	return ''
}

// run_tasks executes tasks in dependency order (DFS, cycle-checked).
// runner maps a task's `run` string to an exit code; the default runner
// re-enters the fcc CLI dispatcher so `run = "compile ..."` just works.
//
// A task that names `outputs` is skipped when every output exists and is
// newer than every input — build.zig's up-to-date check, so unchanged
// rebuilds do nothing. Tasks without outputs always run. `force` (from
// `fcc build --force`) disables the check.
pub fn run_tasks(tasks map[string]TaskDef, targets []string, runner fn (run string) int) ! {
	run_tasks_forced(tasks, targets, runner, false)!
}

// run_tasks_forced is run_tasks with an explicit up-to-date bypass.
pub fn run_tasks_forced(tasks map[string]TaskDef, targets []string, runner fn (run string) int, force bool) ! {
	mut done := map[string]bool{}
	mut stack := map[string]bool{}
	wants := if targets.len == 0 { default_target(tasks) } else { targets }
	for t in wants {
		run_task(tasks, t, runner, mut done, mut stack, force)!
	}
}

fn default_target(tasks map[string]TaskDef) []string {
	if 'default' in tasks {
		return ['default']
	}
	if 'build' in tasks {
		return ['build']
	}
	mut keys := tasks.keys()
	keys.sort()
	return if keys.len > 0 { [keys[0]] } else { []string{} }
}

fn run_task(tasks map[string]TaskDef, name string, runner fn (run string) int, mut done map[string]bool, mut stack map[string]bool, force bool) ! {
	if done[name] {
		return
	}
	if stack[name] {
		return error('build: dependency cycle at task "${name}"')
	}
	t := tasks[name] or { return error('build: unknown task "${name}"') }
	stack[name] = true
	for d in t.depends {
		run_task(tasks, d, runner, mut done, mut stack, force)!
	}
	if !force && is_up_to_date(t) {
		println('task ${name} (up to date)')
		done[name] = true
		stack.delete(name)
		return
	}
	println('task ${name}')
	code := runner(t.run)
	if code != 0 {
		return error('build: task "${name}" failed with exit ${code}')
	}
	stack.delete(name)
	done[name] = true
}

// is_up_to_date reports a task with outputs as skippable: every output
// exists and is newer than every input. Anything else (no outputs, a missing
// output, a missing input, a newer input) means run it.
fn is_up_to_date(t TaskDef) bool {
	if t.outputs.len == 0 {
		return false
	}
	mut newest_input := i64(0)
	for inp in t.inputs {
		stamp := os.file_last_mod_unix(inp)
		if stamp == 0 {
			// A missing or unreadable input cannot prove freshness; the
			// task itself will report the real error.
			return false
		}
		if stamp > newest_input {
			newest_input = stamp
		}
	}
	for out in t.outputs {
		stamp := os.file_last_mod_unix(out)
		if stamp == 0 || stamp < newest_input {
			return false
		}
	}
	return true
}

// exec_shell runs a user-provided shell line (build task `run`, watch
// command). Shell semantics (pipes, redirects) are intentional here, unlike
// compiler-internal spawns which must use os.exec array form.
pub fn exec_shell(run string) os.Result {
	$if windows {
		return os.exec(['cmd', '/c', run])
	} $else {
		return os.exec(['sh', '-c', run])
	}
}

// delegate_build_v hands off to `v run build.v <args>` when the project
// uses a programmatic build file. Returns true when it handled the build.
pub fn delegate_build_v(dir string, args []string) bool {
	p := os.join_path(dir, 'build.v')
	if !os.is_file(p) {
		return false
	}
	vbin := os.find_abs_path_of_executable('v') or { return false }
	mut cmd := [vbin, '-enable-globals', 'run', p]
	cmd << args
	r := os.exec(cmd)
	print(r.output)
	exit(r.exit_code)
	return true
}
