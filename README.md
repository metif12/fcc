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
  **216 match, 4 differ, 0 blocked** — 7 of the original 11 differs were fixed
  (forward-declared enums, `#line` macro expansion, K&R comma-separated
  declarations, array parameter qualifiers, paste whitespace, macro rescan, and
  the `AsmGen.store` crash). The remaining 4 differs are: one ARM64
  calling-convention test (00204, no longer crashes but output differs), and
  three complex-initializer tests (00205, 00210, 00216) that need parser work.
  Every differ carries its tcc control, so a defect in fcc is distinguished from
  a gap tcc shares.
- The chibicc behavioural suite: **9 of 18**. The nine failures are *not* all
  ABI divergences, as this file previously claimed — they are, measured:
  three host-ABI divergences with an explicit expected-vs-got (`_Alignof(long)`,
  `sizeof` of a `long` bitfield, `sizeof(L'0')` — `long`=4 and `wchar_t`=2 on
  this target, matching tcc and mingw gcc), one frontend gap (chibicc's private
  `__va_area__`), one backend crash (invalid memory access in `AsmGen.store`,
  **fixed**), and four behavioural mismatches inside chibicc's own `assert`s.
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

**The front end is target-aware; the back end is not, and it refuses rather than
guessing.** `-target=<triple>` selects the machine fcc compiles *for*:

| triple | data model | codegen |
|---|---|---|
| `x86_64-windows` (default) | `long` 4, `long double` 8, `wchar_t` 2, `__LLP64__`, `_WIN32` | Microsoft x64 ABI |
| `x86_64-linux` | `long` 8, `long double` 16, `wchar_t` 4 **signed**, `__LP64__`, `__linux__` | refused — no System V backend |

Each also answers to the spellings the two toolchains use: `amd64-windows`,
`x86_64-windows-msvc`, `x86_64-pc-windows-msvc`, `amd64-linux`,
`x86_64-linux-gnu`, `x86_64-unknown-linux-gnu`. An unknown triple is a hard
error that lists them; `-target=` with an empty value is an error rather than the
default, because that is what an unset variable expands to. The default is the
target fcc was **built** for, not the one it happens to run on — a compiler that
infers its target from its host cannot cross-compile at all.

`-S` on `x86_64-linux` exits non-zero and says which calling convention is
missing rather than emitting Microsoft x64 code under a Linux name.
`--preprocess` and `--dump-ast` accept any known target, because the data model
and the predefined macros are the front end's and the ABI is not.

```console
$ fcc -target=x86_64-linux --preprocess probe.c   # __SIZE_TYPE__ expands to `unsigned long`
$ fcc -target=x86_64-linux -S -o x.s x.c
fcc: no code generator for x86_64-linux: it needs the sysv-x64 calling convention,
and fcc implements only microsoft-x64. The front end is target-aware, so
--preprocess and --dump-ast accept this target.
```

**Why this shape and not a second platform** (decision D4, "one platform at a
time"; D36 records the split). The three things that differ between targets are
kept apart: the *data model* is `ast.Target` in `src/ast/target.v`, the
*predefined macros* come from the same table, and the *ABI* lives in
`src/ast/abi.v`. The front end can be correct for a machine whose calling
convention is not implemented, provided the compiler then refuses to generate
code for it — which is the only property that makes a partial second target safe.

**What is left to a real second target**, measured rather than guessed:

- the Microsoft x64 ABI already lives alone in `src/ast/abi.v` and is reached
  through **49** sites outside that file, so System V is parameterisation work;
- the backend is monolithic — **425** hardcoded x86-64 register operands across
  `gen.v` and `asm.v`, about 2,350 lines — so a different architecture is a new
  backend;
- the front end's target-dependent numbers are now in one file rather than
  scattered: 14 sites in `types.v` moved into `src/ast/target.v`, and the Linux
  column is measured from gcc 13.3.0, not recalled.

Note that V itself passes `-target` only on its macOS→Linux cross path
(`vlib/v/driver/driver.v:2104`), never on the Windows path fcc serves, so the
flag is parity with tcc rather than a contract item.

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

v -enable-globals -o fcc.exe .
v -enable-globals test .
```

`-enable-globals` is required on **every** `v` invocation here, not only the
build: `src/fcc/types.v` holds the selected target in a `__global`, and stock V
rejects a module-level mutable variable without the flag with `bad top level
statement keyword `mut``.

The end-to-end and conformance runs need two more variables pointing at
scratch space and at a
[c-testsuite](https://github.com/c-testsuite/c-testsuite) checkout:

```powershell
$env:VCC_PROBE_DIR = "$env:LOCALAPPDATA\Temp\opencode\va-probe"
$env:VCC_CTS_DIR = "$env:LOCALAPPDATA\Temp\opencode\c-testsuite"

v -enable-globals run tools/probe/probe.v     # 20 differential programs vs tcc/gcc
v -enable-globals run tools/suite/suite.v     # chibicc suite
v -enable-globals run tools/cts/cts.v         # c-testsuite single-exec (220 cases)
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

## Roadmap

- **Phase 0** — contract capture. Done: `docs/CONTRACT.md` pinned by 12 tests.
- **Phase 1** — C front end. Done: tokenizer, preprocessor, parser, type system.
- **Phase 2** — assembly-text backend. Done: whole translation units compile to
  x86-64 assembly, 20/20 differential programs match, 216/220 c-testsuite cases.
- **Phase 3** — machine-code emitter + object writer. Not started.
- **Open work** (see `docs/PLAN.md`): CTS 00204 (variadic HFA ABI), complex
  initializers (00205, 00216), `__attribute__` in cast types (00210), and
  characterising the remaining chibicc failures.

## Design in one paragraph

The code generator sits behind a `backend.Backend` interface so the expensive
half of the work can be deferred. Phase 2 implements it as text assembly and is
validated against the chibicc test suite; phase 3 swaps in a machine-code
emitter behind the identical interface and adds an object writer. The front end
is written once and never revisited.
