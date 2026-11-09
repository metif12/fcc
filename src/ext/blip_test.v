module ext

// Transpiler-level tests for the Blip input plugin.
fn test_blip_print() {
	out := transpile_blip('print 40 + 2\n', 't.blip')!
	assert out.contains('printf')
	assert out.contains('40 + 2')
}

fn test_blip_let_and_assign() {
	out := transpile_blip('let x = 5\nx = x + 1\nprint x\n', 't.blip')!
	assert out.contains('int x = 5;')
	assert out.contains('x = (x + 1);')
}

fn test_blip_if_else() {
	out := transpile_blip('x = 5\nif x == 5 {\n    print x\n} else {\n    print 0\n}\n', 't.blip')!
	assert out.contains('if (x == 5) {')
	assert out.contains('} else {')
}

fn test_blip_for_loop() {
	out := transpile_blip('for i in 1 2 3 {\n    print i\n}\n', 't.blip')!
	assert out.contains('for (int _bi = 0;')
}

fn test_blip_function() {
	out := transpile_blip('fn dbl(n) {\n    return n * 2\n}\nprint dbl(21)\n', 't.blip')!
	assert out.contains('int dbl(int n) {')
	assert out.contains('return (n * 2);')
}
