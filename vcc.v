module main

import os
import src.driver

// vcc is a C compiler written in pure V, intended to replace the bundled TinyCC
// that the V compiler uses as its default backend on Windows.
//
// The program is a thin shell on purpose: everything that matters lives under
// src/fcc and src/backend, so the compiler can be tested as a library before it
// is trusted as a program.

fn main() {
	driver.main(os.args[1..])
}
