module main

import os
import src.driver

// vcc is a C compiler written in pure V, with a plugin-able and extendable
// architecture: every stage (input, preprocessing, parsing, codegen, assembly,
// object writing, linking, CLI) is an extension behind a registry in src/core.
//
// The program is a thin shell on purpose: everything that matters lives under
// src/fcc, src/backend, src/core and src/ext, so the compiler can be tested as
// a library before it is trusted as a program.

fn main() {
	driver.main(os.args[1..])
}
