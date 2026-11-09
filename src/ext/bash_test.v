module ext

// Transpiler-level tests for the Bash input plugin: the generated C is
// asserted as text, so no toolchain is needed.

fn test_bash_echo_expands_quoted_variable() {
	out := transpile_bash('name="world"\necho hello "$name"\n', 't.sh')!
	assert out.contains('printf("hello %s\\n", name);')
}

fn test_bash_echo_keeps_plain_words() {
	out := transpile_bash('echo hello world\n', 't.sh')!
	assert out.contains('printf("hello world\\n");')
}

fn test_bash_for_loop_expands_counter() {
	out := transpile_bash('for i in 1 2; do\necho count "$i"\ndone\n', 't.sh')!
	assert out.contains('printf("count %s\\n", i);')
}

fn test_bash_if_else_shape() {
	out := transpile_bash('x=5\nif [ $x -eq 5 ]; then\necho yes\nelse\necho no\nfi\n',
		't.sh')!
	assert out.contains('if (x == 5) {')
	assert out.contains('} else {')
	assert out.contains('printf("yes\\n");')
	assert out.contains('printf("no\\n");')
}
