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
- 20 differential end-to-end programs in `tests/endtoend/`, each compared
  against what tcc (or gcc, where tcc refuses) computes for the same program:
  **20 of 20 match**.
- The [c-testsuite](https://github.com/c-testsuite/c-testsuite) single-exec
  suite (220 cases, run from an external checkout via `tools/cts/cts.v`):
  **209 match, 11 differ, 0 blocked** — and every differ carries its tcc
  control, so a defect in fcc is distinguished from a gap tcc shares.
- The chibicc behavioural suite: **9 of 18**. The nine failures are *not* all
  ABI divergences, as this file previously claimed — they are, measured:
  three host-ABI divergences with an explicit expected-vs-got (`_Alignof(long)`,
  `sizeof` of a `long` bitfield, `sizeof(L'0')` — `long`=4 and `wchar_t`=2 on
  this target, matching tcc and mingw gcc), one frontend gap (chibicc's private
  `__va_area__`), one **backend crash** (invalid memory access in `AsmGen.store`),
  and four behavioural mismatches inside chibicc's own `assert`s that are not yet
  individually characterised.
- `v test .`: 10 of 10, on stock V and on the local build.
- CI builds and runs the suite on stock V. Build is green; the two test files
  that fail there are stock-V codegen defects, recorded in `docs/PLAN.md`.

## How ready is this for real C source

Measured on the harnesses above, not estimated.

**Works today.** Whole translation units: the data section with relocations,
initializers and bitfields; the full expression and statement walk; variadic
calls across the boundary into mingw's C library; struct returns of every size;
floating point including `long double`; VLAs; all 19 standard headers. The 20
differential programs and 209 of 220 c-testsuite cases agree with tcc or gcc on
the same program.

**Not yet.** Ten c-testsuite cases are frontend refusals tcc accepts — incomplete
`enum`, multi-declarator declarations, abstract declarators, four
`expected an expression` shapes, `undefined variable` from `##`, and `#line`
with a macro argument. These are unimplemented language features, each with a
tcc control. One case (00204) crashes the compiler; the trigger is in 64-bit
`movi`/`opi` patterns. On the chibicc suite, one backend crash and four
uncharacterised behavioural mismatches are open.

**What "replace tcc" would still need.** The honest gap is not the percentage —
it is that a single crash or wrong answer in a large codebase is enough to stop
someone shipping with it. The 209/220 number counts programs that agree; it does
not count how often fcc is right for the *wrong reason*. Closing that means the
four uncharacterised chibicc mismatches and the 00204 crash, not more percentages.

## Cross-compilation

**Not supported, and by decision rather than by omission** (decision D4, "one
platform at a time"; D35 records wasm as not planned). The target is Win32/Win64
x86-64 and it is hardcoded in three places:

- the preprocessor defines only `_WIN32`, `_WIN64` and `__LLP64__`;
- the type model is fixed — `long` 4, `wchar_t` 2, `long double` 8, pointers 8;
- the backend emits x86-64 only.

The groundwork is better than nothing, and worth being precise about. The
Microsoft x64 ABI lives alone in `src/ast/abi.v` — `gp_max`, `fp_max`,
`shadow_space`, `incoming_base`, the `va_list` shape — and is reached through 49
sites outside that file, so a second x86-64 target is an ABI-parameterisation job
rather than a rewrite. But the backend itself is monolithic: 425 hardcoded
x86-64 register operands across `gen.v` and `asm.v`, about 2,350 lines.

So: a Linux x86-64 target (System V ABI, `long`=8, `wchar_t`=4, `__LP64__`, no
shadow space, different callee-saved set, varargs in `%al`) is a bounded piece of
work. A different architecture is a new backend. Neither is started.

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

v run tools/probe/probe.v     # 20 differential programs vs tcc/gcc
v run tools/suite/suite.v     # chibicc suite
v run tools/cts/cts.v         # c-testsuite single-exec (220 cases)
```

## Diagnostics

Errors print the terse first line the V driver keys on, followed by a
V-style source block — file, line, column, a caret span as wide as the token,
and `= help:` / `= note:` follow-ups where the fix is known:

```
tcc: foo.c:12:9: expected ";", found "bar"
 --> foo.c:12:9
  |
12 | int x = 5  bar = 6;
  |              ^^^
  |
  = help: a declaration or statement ends with `;` — one is missing before this token
```

Macro expansions add a `note: expanded from here` with the definition's own
snippet, so a diagnostic never points at an expansion without naming the macro.

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
