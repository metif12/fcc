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

Phase 2 is done: the compiler translates whole C programs to x86-64 assembly
through a real Windows x64 ABI — variadic calls, callee-saved registers, stack
probes for frames over a page, struct returns, bitfields, and floating point.

- All 19 standard headers compile (`tests/endtoend/stdheaders.c`).
- `fcc -S` writes AT&T assembly for whole translation units: the data section,
  the expression and statement walk, the frame layout, and the ABI's argument
  passing. The output assembles with GNU `as` and links with gcc.
- 19 differential end-to-end programs in `tests/endtoend/`, each compared
  against what tcc (or gcc, where tcc refuses) computes for the same program:
  **19 of 19 match**.
- The [c-testsuite](https://github.com/c-testsuite/c-testsuite) single-exec
  suite (220 cases, run from an external checkout via `tools/cts/cts.v`):
  **198 match, 22 differ, 0 blocked** — and every differ carries its tcc
  control, so a defect in fcc is distinguished from a gap tcc shares.
- The chibicc suite: 9 of 18 pass; the 9 failures are host-ABI divergences
  (`long`=4, `wchar_t`=2 on this target), not defects.
- `v test .`: 9 of 9.

`fcc --preprocess` prints the token stream. `fcc --dump-ast` prints every global
and function with its layout, initial data, relocations and frame, and every
function body as parsed statements.

Two constructs are reported rather than translated, and both need a node kind
the backend must implement anyway: `asm` statements with register constraints,
and compound assignment to an `_Atomic` object.

## Layout

```
src/          the compiler
  fcc/           tokenizer, preprocessor, parser, types
  ast/           syntax tree and types
  backend/       the swappable code generation interface
  driver/        command line, invocation contract
vcc.v         entry point (the binary is `fcc.exe`)
tests/        unit tests (`contract/`) and differential probes (`endtoend/`)
tools/        harnesses: `probe` (endto-end vs tcc), `suite` (chibicc),
              `cts` (c-testsuite single-exec), `harness`, `onefile`
docs/         research, plan, and session log
notes/        decision log
```

## Build

Prerequisites: the V toolchain plus a checkout of
[vlang/v](https://github.com/vlang/v) — fcc takes its oracle (`tcc`) and its
linker (`gcc`) from there.

```powershell
$env:PATH = 'C:\path\to\v;' + $env:PATH
$env:VCC_V_ROOT = 'C:\path\to\v'
$env:V_MACOS_V3_NO_FALLBACK = '1'
$env:TMPDIR = "$env:LOCALAPPDATA\Temp\opencode\vccbuild"
$env:VJOBS = '4'

v -o fcc.exe .
v test .
```

The end-to-end and conformance runs need two more variables pointing at
scratch space and at a
[c-testsuite](https://github.com/c-testsuite/c-testsuite) checkout:

```powershell
$env:VCC_PROBE_DIR = "$env:LOCALAPPDATA\Temp\opencode\va-probe"
$env:VCC_CTS_DIR = "$env:LOCALAPPDATA\Temp\opencode\c-testsuite"

v run tools/probe/probe.v     # 19 differential programs vs tcc/gcc
v run tools/suite/suite.v     # chibicc suite
v run tools/cts/cts.v         # c-testsuite single-exec (220 cases)
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
