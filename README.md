# vcc

A C compiler written in pure V, aimed at replacing the bundled TinyCC that
[vlang/v](https://github.com/vlang/v) uses as its default C backend on Windows.

`v` emits C (`-std=gnu11`) and hands it to `thirdparty/tcc/tcc.exe`. That is a
~60 KB prebuilt binary plus `libtcc.dll`, a header set, `.def` import libraries,
`libtcc1.a`, `openlibm.o` and CRT glue — none of it in this repository, all of it
fetched and rebuilt out of tree by `thirdparty/tcc/build.ps1`. `vcc` exists to
make that dependency pure V, and therefore buildable from V source like the rest
of the toolchain.

See `docs/PLAN.md` for the phased plan and `docs/RESEARCH.md` for the survey of
existing projects this one is built from.

## Status

Phases 0 and 1 are done: the tokenizer, preprocessor, macro expansion, `#if` evaluator,
type system and the whole C declaration and statement grammar.

- `vcc --preprocess` prints the token stream.
- `vcc --dump-ast` prints every global and function with its layout, initial data,
  relocations and frame, and every function body as parsed statements.

Every layout assertion in the test suite is a byte image produced by the bundled tcc,
not an expectation derived from the algorithm under test. Two constructs are reported
rather than translated, and both need a node kind the backend must implement anyway:
`asm` statements, and compound assignment to an `_Atomic` object.

The code generator is started. `vcc -S` writes AT&T assembly for the data section —
initializers, string literals, relocations, `.bss` and the psABI's alignment rules — and
the output assembles into a PE object with GNU `as`. A translation unit with a
function definition is reported rather than emitted, because the expression and
statement walk is not written yet and an object that links and does the wrong thing
is worse than one that refuses to be produced.

## Layout

```
src/          the compiler
  vcc/           tokenizer, preprocessor, parser, types
  backend/       the swappable code generation interface
  driver.v       command line, invocation contract
vcc.v          entry point
tests/         vcc's own unit tests
tools/         differential harness against the real tcc
notes/         decision log
docs/          research and plan
```

## Build

```
v -o vcc.exe .
```

## Design in one paragraph

The code generator sits behind a `backend.Backend` interface so the expensive
half of the work can be deferred. Phase 2 implements it as text assembly and is
validated against the chibicc test suite; phase 3 swaps in a machine-code
emitter behind the identical interface and adds an object writer. The front end
is written once and never revisited.