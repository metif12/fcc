module ext

import os
import src.core
import src.fcc

// Example language plugin: Bash.
//
// Claims .sh / .bash files and turns them into a C translation unit that
// carries the script text and runs it through the host shell. Like the
// Brainfuck plugin, it reuses the whole existing pipeline (frontend, both
// emitters, object writer) without touching any of it.
//
// It is registered by register_bash (called from driver.ensure_extensions, so
// `fcc -c hello.sh` works out of the box) and stays out of register_defaults.
// Disable it without touching code:
//
//   [plugin."example-bash-input"]
//   enabled = false

pub struct BashInput {
pub:
	plugin_name string = 'example-bash-input'
}

pub fn (p BashInput) name() string {
	return p.plugin_name
}

pub fn (p BashInput) extensions() []string {
	return ['.sh', '.bash']
}

pub fn (p BashInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.sh') || l.ends_with('.bash')
}

pub fn (p BashInput) load(path string, mut ctx core.PipelineContext) ! {
	src := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	generated := transpile_bash(src, path) or {
		ctx.diagnostics << err.msg()
		ctx.failed = true
		return error('bash: ${err.msg()}')
	}
	mut pp := fcc.preprocessor(ctx.includes, ctx.sys_includes)
	for spec in ctx.defines {
		pp.define_from_option(spec)
	}
	for n in ctx.undefines {
		pp.undefine(n)
	}
	pp.define_builtins()
	pre := pp.run_text(generated, path)
	for e in pre.errors {
		ctx.diagnostics << '${path}: ${e}'
		ctx.failed = true
	}
	parsed := fcc.parse_tokens(pre.tokens, path, pp.packs)
	for e in parsed.errors {
		ctx.diagnostics << e
		ctx.failed = true
	}
	for w in parsed.warnings {
		ctx.diagnostics << w
	}
	if parsed.errors.len > 0 {
		return error('parse failed for ${path}')
	}
	ctx.globals << parsed.globals
}

pub fn register_bash() {
	core.register_input(BashInput{})
}

// transpile_bash turns a shell script into a C translation unit. The script
// text is embedded as a C string and handed to the system's shell at runtime,
// so the resulting binary still needs a shell on the target machine.
pub fn transpile_bash(src string, origin string) !string {
	mut out := []string{}
	out << '/* generated from ${origin} by example-bash-input */'
	out << '#include <stdlib.h>'
	out << 'int main(void) {'
	out << '  static const char bash_script[] ='
	// Emit the script as a sequence of adjacent string literals, one per
	// source line, so escaping stays local and readable.
	for line in src.split('\n') {
		out << '    "${escape_c(line)}\\n"'
	}
	out << '    ;'
	out << '  return system(bash_script);'
	out << '}'
	return out.join('\n')
}

fn escape_c(s string) string {
	mut r := ''
	for c in s {
		match c {
			`\\` { r += '\\\\' }
			`"` { r += '\\"' }
			`\n` { r += '\\n' }
			`\t` { r += '\\t' }
			`\r` { r += '\\r' }
			else { r += c.ascii_str() }
		}
	}
	return r
}