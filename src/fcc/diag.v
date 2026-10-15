module fcc

import ast

// V-style diagnostics: a snippet with a caret under the terse first line.
//
// Every diagnostic this compiler emits is a string whose first line is the
// terse `tcc: file:line: message` the V driver keys on (D22) — that line never
// changes shape. What follows it, when there is source to show, is the block
// this file builds:
//
//   tcc: foo.c:12:9: expected ";", found "bar"
//    --> foo.c:12:9
//     |
//   12 | int x = 5  bar = 6;
//     |           ^^^
//     |
//     = help: statements end with `;`
//
// The block is plain text, never color: color is a TTY decision and this
// compiler's output is parsed by tools as often as it is read. The first line
// stays byte-identical either way, so nothing that reads diagnostics changes.

// diag_block renders the source block for a token: the --> pointer, the source
// line with its number, and a caret span `len` bytes wide starting at the
// token's column. It returns '' when there is nothing to show — a synthesized
// location has no file, and a file the tokenizer never read has no contents —
// so callers append what comes back without branching.
fn diag_block(tok ast.Token) string {
	if fl := tok.line.file {
		return diag_block_in(tok, fl)
	} else {
		// A synthesized location has no file and therefore no source to show;
		// the terse first line already carries the message.
		return ''
	}
}

// diag_block_in renders once the file is known to exist.
fn diag_block_in(tok ast.Token, fl &ast.File) string {
	if tok.line.disp_line < 1 {
		return ''
	}
	lines := fl.contents.split_into_lines()
	if tok.line.disp_line > lines.len {
		return ''
	}
	src := lines[tok.line.disp_line - 1]
	// Tabs would move the caret off the token: expand them for display and
	// measure the caret in the expanded space, so the carets land under what
	// the eye sees.
	disp := src.replace('\t', '    ')
	col := tok.line.disp_col
	if col < 1 {
		return ''
	}
	// The caret starts under the token's first byte and runs `len` bytes, cut
	// at the line's end so a span that runs past it (a token at end of line,
	// an unterminated construct) still points at something.
	start := expanded_col(disp, src, col)
	mut width := tok.len
	if width < 1 {
		width = 1
	}
	mut end := start + width
	if end > disp.len {
		end = disp.len
	}
	mut s := start
	if s > disp.len {
		s = disp.len
	}
	// The span cannot be empty: clamping the end to the line may have pulled it
	// back onto the start, and a zero-width caret points at nothing.
	if end <= s && s < disp.len {
		end = s + 1
	}
	num := tok.line.disp_line.str()
	gutter := ' '.repeat(num.len)
	mut b := '\n --> ${fl.name}:${tok.line.disp_line}:${col}\n'
	b += '${gutter} |\n'
	b += '${num} | ${disp}\n'
	b += '${gutter} | ${' '.repeat(s)}${'^'.repeat(end - s)}'
	return b
}

// expanded_col maps a 1-based byte column in the raw line to a 0-based offset
// in the tab-expanded display line.
fn expanded_col(disp string, src string, col int) int {
	mut d := 0
	mut i := 0
	mut c := 1
	for i < src.len && c < col {
		if src[i] == `\t` {
			d += 4
		} else {
			d++
		}
		i++
		c++
	}
	if d > disp.len {
		return disp.len
	}
	return d
}

// diag_notes renders the macro-expansion chain behind a token, most recent
// first. Each level is a location plus its own snippet — the same block as the
// primary — capped, because a recursive macro's chain is long and every level
// past the first few stops helping.
fn diag_notes(tok ast.Token) string {
	mut b := ''
	mut cur := tok.origin
	mut depth := 0
	for {
		if o := cur {
			if depth >= 3 {
				break
			}
			block := diag_block(o)
			if block == '' {
				break
			}
			b += '\n     = note: expanded from here${block}'
			cur = o.origin
			depth++
		} else {
			break
		}
	}
	return b
}
