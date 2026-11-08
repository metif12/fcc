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
pub fn run_tasks(tasks map[string]TaskDef, targets []string, runner fn (run string) int) ! {
	mut done := map[string]bool{}
	mut stack := map[string]bool{}
	wants := if targets.len == 0 { default_target(tasks) } else { targets }
	for t in wants {
		run_task(tasks, t, runner, mut done, mut stack)!
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

fn run_task(tasks map[string]TaskDef, name string, runner fn (run string) int, mut done map[string]bool, mut stack map[string]bool) ! {
	if done[name] {
		return
	}
	if stack[name] {
		return error('build: dependency cycle at task "${name}"')
	}
	t := tasks[name] or { return error('build: unknown task "${name}"') }
	stack[name] = true
	for d in t.depends {
		run_task(tasks, d, runner, mut done, mut stack)!
	}
	println('task ${name}')
	code := runner(t.run)
	if code != 0 {
		return error('build: task "${name}" failed with exit ${code}')
	}
	stack.delete(name)
	done[name] = true
}

// delegate_build_v hands off to `v run build.v <args>` when the project
// uses a programmatic build file. Returns true when it handled the build.
pub fn delegate_build_v(dir string, args []string) bool {
	p := os.join_path(dir, 'build.v')
	if !os.is_file(p) {
		return false
	}
	vbin := os.find_abs_path_of_executable('v') or { return false }
	cmd := '${vbin} -enable-globals run ${p} ${args.join(' ')}'
	r := os.execute(cmd)
	print(r.output)
	exit(r.exit_code)
	return true
}
