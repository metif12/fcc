// build.v: programmatic build (like build.zig).
// Run with: fcc build  (delegates to `v run build.v` when no build.blip task matches)
// Copy to build.v at your project root and edit the steps.

module main

import os

fn sh(cmd string) {
	println('+ ${cmd}')
	r := os.execute(cmd)
	print(r.output)
	if r.exit_code != 0 {
		eprintln('build.v: step failed: ${cmd}')
		exit(1)
	}
}

fn main() {
	args := os.args[1..]
	target := if args.len > 0 { args[0] } else { 'build' }
	match target {
		'build' {
			sh('fcc -S -o main.s main.c')
		}
		'tokens' {
			sh('fcc --dump-tokens main.c')
		}
		'all' {
			sh('fcc -S -o main.s main.c')
			sh('fcc --dump-tokens main.c')
		}
		else {
			eprintln('unknown task: ${target} (try: build, tokens, all)')
			exit(1)
		}
	}
}
