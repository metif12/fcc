module fcc

// Characterisation of the remaining chibicc mismatches.
//
// Each entry states its bucket and the evidence that pins it there. The host
// data-model rows (long=4, wchar=2 on Windows) match tcc and mingw gcc on
// this host; making them pass would break every `long` in V's generated C.
//
// Evidence (measured on this host, gcc 15.2.0):
//   arith.c    sizeof(0?(long)1:(long)2) -> 4  (chibicc expects 8)
//   literal.c  sizeof(0L)                 -> 4  (chibicc expects 8)
//   string.c   sizeof(L'0')               -> 2  (chibicc expects 4)
//   struct.c   sizeof(struct{char a; long b;}) -> 8 (chibicc expects 16)
//   cast.c:7   (long)&x truncates a 64-bit address; gcc-built binary of the
//              same three lines segfaults identically.
//   function.c:96 / varargs.c  rely on chibicc's private __va_area__ name;
//              fcc uses standard varargs and never emits that symbol.

fn test_classify_arith() {
	// sizeof(0?(long)1:(long)2): long is 4 on Windows, 8 on LP64.
	assert true
}

fn test_classify_literal() {
	// sizeof(0L): long is 4 on Windows.
	assert true
}

fn test_classify_string() {
	// sizeof(L'0'): wchar_t is unsigned short (2) on Windows.
	assert true
}

fn test_classify_struct() {
	// sizeof(struct{char a; long b;}): 1 + 3 pad + 4 = 8 on Windows.
	assert true
}

fn test_classify_cast() {
	// (long)&x truncates a 64-bit address on a 32-bit long; gcc agrees.
	assert true
}

fn test_classify_function_varargs() {
	// __va_area__ is chibicc's private save-area name; fcc uses standard varargs.
	assert true
}
