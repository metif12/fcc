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

Phase 0 — contract capture. The C front end has not been written yet.

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