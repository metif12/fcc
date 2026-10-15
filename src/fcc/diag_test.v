module fcc

import ast

// Diagnostics tests.
//
// The contract under test is twofold and both halves matter: the terse first
// line never changes shape (the V driver keys on its `tcc:` prefix, and a dozen
// tests assert on it with `.contains`), and the block under it points at the
// right bytes. A caret under the wrong token is worse than no caret, because it
// sends the reader to innocent code with confidence.

// diag_file builds the file a snippet test needs: contents the block reads back.
fn diag_file(name string, contents string) &ast.File {
	return &ast.File{
		name:     name
		contents: contents
	}
}

fn diag_tok(file &ast.File, line int, col int, len int) ast.Token {
	return ast.Token{
		kind: .ident
		text: 'bar'
		line: ast.Line{
			file:      file
			disp_line: line
			disp_col:  col
		}
		len:  len
	}
}

fn test_the_block_points_at_the_token() {
	f := diag_file('foo.c', 'int x = 5  bar = 6;\n')
	b := diag_block(diag_tok(f, 1, 12, 3))
	assert b.contains('--> foo.c:1:12'), 'missing pointer: ${b}'
	assert b.contains('1 | int x = 5  bar = 6;'), 'missing source line: ${b}'
	lines := b.split_into_lines()
	caret := lines[lines.len - 1]
	src_line := lines[lines.len - 2]
	// The carets sit under the token in the source line above.
	assert caret.count('^') == 3, 'caret width is not the token width: [${caret}]'
	assert caret.index('^') or { -1 } == src_line.index('bar') or { -2 }, 'caret is not under the token: [${caret}] vs [${src_line}]'
}

fn test_a_span_longer_than_the_token_is_honored() {
	f := diag_file('foo.c', 'ab;\n')
	b := diag_block(diag_tok(f, 1, 1, 2))
	assert b.contains('^^'), 'expected two carets: ${b}'
}

fn test_a_span_past_the_line_end_is_cut_not_lost() {
	f := diag_file('foo.c', 'ab;\n')
	b := diag_block(diag_tok(f, 1, 2, 99))
	assert b.contains('^'), 'expected a caret even for an overlong span: ${b}'
}

fn test_tabs_do_not_move_the_caret_off_the_token() {
	f := diag_file('foo.c', '\tbar = 6;\n')
	b := diag_block(diag_tok(f, 1, 2, 3))
	assert b.contains('bar = 6;'), 'tab was not expanded for display: ${b}'
	lines := b.split_into_lines()
	caret := lines[lines.len - 1]
	bar := lines[lines.len - 2].index('bar') or { -1 }
	assert caret.index('^') or { -2 } == bar, 'caret [${caret}] is not under bar in [${lines[lines.len - 2]}]'
}

fn test_a_synthesized_location_shows_nothing() {
	// No file: the terse line carries the message alone.
	t := ast.Token{
		kind: .ident
		text: 'x'
		line: ast.Line{
			disp_line: 3
			disp_col:  1
		}
		len:  1
	}
	assert diag_block(t) == '', 'a fileless token must not render a block'
}

fn test_a_line_past_the_end_shows_nothing() {
	f := diag_file('foo.c', 'int x;\n')
	assert diag_block(diag_tok(f, 9, 1, 1)) == '', 'a line past EOF must not render a block'
}

fn test_notes_follow_the_origin_chain() {
	f := diag_file('foo.c', '#define X 1\nint y = X;\n')
	use_tok := diag_tok(f, 2, 9, 1)
	def_tok := diag_tok(f, 1, 9, 1)
	mut use_ := use_tok
	mut def_ := def_tok
	use_.origin = &def_
	n := diag_notes(use_)
	assert n.contains("expanded from here"), 'missing note: ${n}'
	assert n.contains('foo.c:1:9'), 'note points at the wrong place: ${n}'
}
