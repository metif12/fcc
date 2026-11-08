module ext

import os
import src.core
import src.fcc

// Example language plugin: Brainfuck.
//
// This is the worked example for docs/PLUGINS.md "Writing a plugin". It shows
// the smallest thing that counts as a language: an InputPlugin claiming a new
// file extension, transpiling to C, and reusing the whole existing pipeline
// (frontend, both emitters, object writer) without touching any of it.
//
// It is registered by register_bf (called from driver.ensure_extensions, so
// `fcc -c hello.bf` works out of the box) and stays out of register_defaults,
// so the stock pipeline is unchanged. Disable it without touching code:
//
//   [plugin."example-bf-input"]
//   enabled = false
//
// Design notes, all deliberate:
//   - Cells are `unsigned char`, so `+`/`-` wrap exactly like classic BF.
//   - Only I/O needs declarations; `putchar`/`getchar` are declared, not
//     included, the way tests/endtoend programs declare `printf` — so no
//     headers are required.
//   - Non-command bytes are ignored, so BF files can carry comments.
//   - Diagnostics name the .bf file, line and column. One known limitation:
//     errors from the *generated* C (there should be none — the generator
//     only emits shapes the endtoend corpus covers) point at generated
//     lines, because no `#line` mapping is emitted.

pub const bf_tape_cells = 30000

pub struct BfInput {
pub:
	plugin_name string = 'example-bf-input'
}

pub fn (p BfInput) name() string {
	return p.plugin_name
}

pub fn (p BfInput) extensions() []string {
	return ['.bf', '.b']
}

pub fn (p BfInput) can_handle(path string) bool {
	l := path.to_lower()
	return l.ends_with('.bf') || l.ends_with('.b')
}

pub fn (p BfInput) load(path string, mut ctx core.PipelineContext) ! {
	src := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	generated := transpile_bf(src, path) or {
		ctx.diagnostics << err.msg()
		ctx.failed = true
		return error('brainfuck: ${err.msg()}')
	}
	// Same front end as CFileInput, fed from generated text instead of a
	// file: run_text keeps `path` for diagnostics.
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

pub fn register_bf() {
	core.register_input(BfInput{})
}

// transpile_bf turns Brainfuck source into a C translation unit. `origin
// names the file for diagnostics, which carry line and column of the
// offending bracket.
pub fn transpile_bf(src string, origin string) !string {
	// Validate brackets first, so an unbalanced program fails before any
	// code is generated rather than emitting half a loop.
	mut open_lines := []int{}
	mut open_cols := []int{}
	mut line := 1
	mut col := 1
	for b in src {
		if b == `[` {
			open_lines << line
			open_cols << col
		} else if b == `]` {
			if open_lines.len == 0 {
				return error('${origin}:${line}:${col}: unmatched ' + "']'")
			}
			open_lines.pop()
			open_cols.pop()
		}
		if b == `\n` {
			line++
			col = 1
		} else {
			col++
		}
	}
	if open_lines.len > 0 {
		return error('${origin}:${open_lines.last()}:${open_cols.last()}: unclosed ' +
			"'['")
	}
	mut out := []string{}
	out << '/* generated from ${origin} by example-bf-input */'
	out << 'int putchar(int c);'
	out << 'int getchar(void);'
	out << 'unsigned char bf_tape[${bf_tape_cells}];'
	out << 'int main(void) {'
	out << '  unsigned char *bf_ptr = bf_tape;'
	mut depth := 0
	for b in src {
		indent := '  ' + '  '.repeat(depth + 1)
		match b {
			`>` { out << '${indent}++bf_ptr;' }
			`<` { out << '${indent}--bf_ptr;' }
			`+` { out << '${indent}++*bf_ptr;' }
			`-` { out << '${indent}--*bf_ptr;' }
			`.` { out << '${indent}putchar(*bf_ptr);' }
			`,` { out << '${indent}*bf_ptr = getchar();' }
			`[` {
				out << '${indent}while (*bf_ptr) {'
				depth++
			}
			`]` {
				depth--
				out << '${'    '.repeat(depth + 1)}}'
			}
			else {}
		}
	}
	out << '  return 0;'
	out << '}'
	return out.join('\n')
}
