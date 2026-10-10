# fcc

**fcc** — a *fast C compiler* written in pure V, aimed at replacing the bundled TinyCC that
[vlang/v](https://github.com/vlang/v) uses as its default C backend on Windows.

`v` emits C (`-std=gnu11`) and hands it to `thirdparty/tcc/tcc.exe`. That is a
~60 KB prebuilt binary plus `libtcc.dll`, a header set, `.def` import libraries,
`libtcc1.a`, `openlibm.o` and CRT glue — none of it in this repository, all of it
fetched and rebuilt out of tree by `thirdparty/tcc/build.ps1`. `fcc` exists to
make that dependency pure V, and therefore buildable from V source like the rest
of the toolchain.

See `docs/PLAN.md` for the phased plan and `docs/RESEARCH.md` for the survey of
existing projects this one is built from.

## Status

Phases 0 and 1 are done: the tokenizer, preprocessor, macro expansion, `#if` evaluator,
type system and the whole C declaration and statement grammar.

- `fcc --preprocess` prints the token stream.
- `fcc --dump-ast` prints every global and function with its layout, initial data,
  relocations and frame, and every function body as parsed statements.

Every layout assertion in the test suite is a byte image produced by the bundled tcc,
not an expectation derived from the algorithm under test. Two constructs are reported
rather than translated, and both need a node kind the backend must implement anyway:
`asm` statements, and compound assignment to an `_Atomic` object.

The chibicc test suite is wired up and running against it: 7 of its 18 files compile,
assemble, link and execute, and the 11 that fail each fail on a defect that is recorded
in docs/PLAN.md.

`fcc -S` writes AT&T assembly for whole translation units: the data section,
the expression and statement walk, the frame layout and the psABI's argument passing.
The output assembles into a PE object with GNU `as` and links with gcc, and five
programs built this way are executed and checked against the values tcc computes for
the same expressions — loops, `switch` with a case range, `goto`, array indexing
through a parameter, struct return, bitfields and floating point.

## Layout

```
src/          the compiler
  fcc/           tokenizer, preprocessor, parser, types
  backend/       the swappable code generation interface
  driver.v       command line, invocation contract
fcc.v          entry point
tests/         fcc's own unit tests
tools/         differential harness against the real tcc
notes/         decision log
docs/          research and plan
```

## Build

```
v -o fcc.exe .
```

## One name, two spellings — and why the diagnostics are still prefixed `tcc:`

The product is `fcc`. Its **diagnostics are prefixed `tcc:` and that is deliberate**,
not an oversight left over from the rename.

`v3_is_tcc_compilation_failure` in vlang's driver treats any output line beginning with
`tcc:` as a compiler failure, and a compiler that reported errors in a format V does
not recognise would make V fall back to `cc` instead of surfacing what went wrong. See
`src/fcc/parser.v` and decision D22 in `notes/DECISIONS.md`.

So: `fcc.exe` builds, `fcc -S` compiles, `fcc: ` is what the driver prints — and
`tcc: ` is what a compiler error looks like from V's side.

## Design in one paragraph

The code generator sits behind a `backend.Backend` interface so the expensive
half of the work can be deferred. Phase 2 implements it as text assembly and is
validated against the chibicc test suite; phase 3 swaps in a machine-code
emitter behind the identical interface and adds an object writer. The front end
is written once and never revisited.
