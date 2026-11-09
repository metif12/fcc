# fcc

**fcc** — a *fast, plugin-able and extendable C compiler* written in pure V.

`fcc` is a C compiler (`-std=gnu11`) that compiles to x86-64 assembly and
assembles it in-process to COFF/ELF objects, with no external assembler and no
bundled `tcc` binary. Every stage — tokenizing, preprocessing, parsing, code
generation, assembly, object writing, linking, and the command line itself — is
an extension behind a registry (`src/core`); the stock compiler ships as
default extensions (`src/ext`), and config (`fcc.toml`/`fcc.blip`) or a
plugin can disable, replace or extend any of them without touching the core.

It began as a pure-V replacement for the TinyCC that `vlang/v` uses as its
default C backend on Windows, and that remains a supported use, but the goal
now is a compiler that is fast to build, fast to run, and fast to extend: drop
in a new input language, a new backend, or a new target without forking the
front end. Brainfuck (`src/ext/bf.v`, `examples/hello.bf`) ships as a worked
example of a whole language added in ~100 lines.

See `docs/PLAN.md` for the phased plan, `docs/PLUGINS.md` for the extension
architecture, and `docs/RESEARCH.md` for the survey of existing projects this
one is built from.

## Status

fcc is a working, plugin-able C compiler: it translates whole C programs to
x86-64 assembly, assembles that text in-process to machine code, and writes
COFF (Windows) and ELF (Linux) objects, with no external assembler involved.
The C front end is validated against three independent oracles; the plugin
system is exercised by the Brainfuck language plugin and by the CLI/config/build
commands that ship with it.

- All 19 standard headers compile (`tests/endtoend/stdheaders.c`).
- `fcc -S` writes AT&T assembly for whole translation units: the data section,
  the expression and statement walk, the frame layout, and the ABI's argument
  passing. `fcc -c` assembles it in-process (`src/masm`, a two-pass x86-64
  assembler for exactly the emitted dialect, including GAS's jump relaxation)
  and writes a COFF object (`src/coff`) or ELF object (`src/elf`); the bytes
  match what GNU `as` produces, instruction for instruction
  (`tools/objtest`: 20 match, 0 differ, 0 blocked, 0 flaky). `--extern-as`
  keeps the old `as` path for bisection.
- 20 differential end-to-end programs in `tests/endtoend/`, each compared
  against what tcc (or gcc, where tcc refuses) computes for the same program:
  **20 of 20 match**.
- The [c-testsuite](https://github.com/c-testsuite/c-testsuite) single-exec
  suite (220 cases, run from an external checkout via `tools/cts/cts.v`):
  **220 match, 0 differ, 0 blocked**.
- The chibicc behavioural suite: **17 of 41** passing, with the remaining
  failures characterised (host-ABI divergences, chibicc's private
  `__va_area__`, and a few uncharacterised mismatches) rather than papered
  over. Open items are tracked per case in `docs/PLAN.md`.
- `v test .`: 15 of 15, on stock V and on the local build.
- CI builds and runs the suite on stock V. Build is green.

## What "plugin-able" means here

Nothing in fcc is special-cased. Inputs (`default-c-input`, `default-raw-input`,
`example-bf-input`), outputs (`default-asm`, `default-obj`, `default-exe`, ...),
hooks (`default-target-hook`, `default-verbose-hook`), and CLI commands
(`build`, `plugin`, `config`, `init`, plus any `fcc-<verb>` on `PATH`) are all
registered with the same interface in `src/core`. Config (`fcc.toml`/`fcc.blip`)
enables, disables and tunes them; `fcc plugin list` shows what is registered.
A new language, target, or output format is an extension, not a fork.

## Cross-compilation

**The front end is target-aware; the back end is not, and it refuses rather than
guessing.** `-target=<triple>` selects the machine fcc compiles *for*:

| triple | data model | codegen |
|---|---|---|
| `x86_64-windows` (default) | `long` 4, `long double` 8, `wchar_t` 2, `__LLP64__`, `_WIN32` | Microsoft x64 ABI |
| `x86_64-linux` | `long` 8, `long double` 16, `wchar_t` 4 **signed**, `__LP64__`, `__linux__` | System V ABI |

Each also answers to the spellings the two toolchains use: `amd64-windows`,
`x86_64-windows-msvc`, `x86_64-pc-windows-msvc`, `amd64-linux`,
`x86_64-linux-gnu`, `x86_64-unknown-linux-gnu`. An unknown triple is a hard
error that lists them; `-target=` with an empty value is an error rather than the
default, because that is what an unset variable expands to. The default is the
target fcc was **built** for, not the one it happens to run on — a compiler that
infers its target from its host cannot cross-compile at all.

`-S` and `-c` now work on `x86_64-linux` too, emitting the System V calling
convention. `--preprocess` and `--dump-ast` accept any known target, because the
data model and the predefined macros are the front end's and the ABI is not.

```console
$ fcc -target=x86_64-linux --preprocess probe.c   # __SIZE_TYPE__ expands to `unsigned long`
$ fcc -target=x86_64-linux -S -o x.s x.c          # emits System V ABI assembly
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

One construct is reported rather than translated, and needs a node kind the
backend must implement anyway: `asm` statements with register constraints.

## Layout

```
src/          the compiler
  fcc/           tokenizer, preprocessor, parser, types
  ast/           syntax tree and types
  backend/       the swappable code generation interface
  masm/          in-process x86-64 assembler for the emitted dialect
  coff/          COFF object writer (Windows x86-64 objects, no external as)
  elf/           ELF64 writer (Linux objects; -c on linux still uses WSL as)
  core/          plugin registries, pipeline runner, config (TOML/blip),
                 build tasks, extensible CLI dispatch
  ext/           default extensions plus the worked example language plugin
  driver/        command line, invocation contract
vcc.v         entry point (the binary is `fcc.exe`)
tests/        unit tests (`contract/`) and differential probes (`endtoend/`)
tools/        harnesses: `probe` (endto-end vs tcc), `suite` (chibicc),
              `cts` (c-testsuite single-exec), `harness`, `onefile`,
              `objtest` (native -c vs `as`: bytes and linked behavior)
docs/         research, plan, plugin guide, and session log
notes/        decision log
examples/     `fcc.toml`/`fcc.blip`, `build.v`/`build.blip`, `hello.bf`
```

## Plugins

Every stage of fcc is an extension behind a registry (`src/core`); the stock
compiler ships as default extensions (`src/ext`), and the driver diverts any
input a non-default input plugin claims into the plugin pipeline. Config
(`fcc.toml`/`fcc.blip`) enables, disables and tunes them; `fcc plugin list`
shows what is registered. See `docs/PLUGINS.md`.

The worked example is Brainfuck (`example-bf-input`, `src/ext/bf.v`): it
claims `.bf` files, transpiles to C, and reuses the whole pipeline. It works
out of the box:

```console
$ fcc -c -o hello.o examples/hello.bf
$ gcc -o hello.exe hello.o
$ ./hello.exe
Hello World!
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
$env:FCC_OBJTEST_DIR = "$env:LOCALAPPDATA\Temp\opencode\va-objtest"

v -enable-globals run tools/probe/probe.v     # 20 differential programs vs tcc/gcc
v -enable-globals run tools/suite/suite.v     # chibicc suite
v -enable-globals run tools/cts/cts.v         # c-testsuite single-exec (220 cases)
v -enable-globals run tools/objtest/objtest.v # native -c vs as: bytes and linked behavior
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

## C to V translation (`--to-v` and `--to-v-bindings`)

fcc ships two C→V modes on the legacy path:

- `fcc --to-v file.c` — best-effort translator: prints V source (or `-o out.v`
  writes it). It reuses the C front end and emits structs, enums, typedefs,
  function signatures, globals, and statement/expression bodies where they map
  cleanly; constructs V has no equivalent for (unions, bitfields, flexible
  arrays, `goto`/labels, VLA, K&R parameters, statement expressions) are left
  as comments rather than dropped. The output is a readable port, not a
  guaranteed compilable one — review before use.
- `fcc --to-v-bindings file.c` — emits c2v-style V bindings to the original C
  instead of translating its logic: `@[c_extern] __global C.x T` globals and
  `fn C.foo(...)` extern declarations, plus the struct/union types they need.
  The output compiles by construction (it calls into the real C). Pair with
  `fcc -c -o file.o file.c` and link the object: see the workflow in
  `docs/PLAN.md`.

The two modes make fcc strictly more capable than vlang/c2v, with no clang
dependency." oldString="## C to V translation (`--to-v`)

fcc ships a best-effort C→V translator on the legacy path: `fcc --to-v file.c`
prints V source (or `-o out.v` writes it). It reuses the C front end and emits
structs, enums, typedefs, function signatures, globals, and statement/expression
bodies where they map cleanly; constructs V has no equivalent for (unions,
bitfields, flexible arrays, `goto`/labels, VLA, K&R parameters, statement
expressions) are left as comments rather than dropped. The output is a readable
port, not a guaranteed compilable one — review before use." path="C:\Users\MR\Projects\vcc/README.md

## Roadmap

- **Phase 0** — contract capture. Done: `docs/CONTRACT.md` pinned by 12 tests.
- **Phase 1** — C front end. Done: tokenizer, preprocessor, parser, type system.
- **Phase 2** — assembly-text backend. Done: whole translation units compile to
  x86-64 assembly, 20/20 differential programs match, 220/220 c-testsuite cases.
- **Phase 3** — machine-code emitter + object writer. Done: `-c` assembles
  in-process (`src/masm`) and writes COFF (`src/coff`) and ELF (`src/elf`)
  with no external `as`; `--extern-as` keeps the old path for bisection.
  `tools/objtest`: 20 match, 0 differ, 0 blocked, 0 flaky.
- **Phase 4** — plugin architecture. Done: inputs, outputs, hooks, CLI commands
  and config (`fcc.toml`/`fcc.blip`) behind registries in `src/core`; stock
  compiler ships as default extensions in `src/ext`; Brainfuck as the worked
  example. See `docs/PLUGINS.md`.
- **Open work** (see `docs/PLAN.md`): System V / x86-64-linux backend (the
  front end is already target-aware and refuses codegen there), a second
  architecture backend, characterising the remaining chibicc failures, and
  extending the masm/coff/elf writers to new targets.

## Design in one paragraph

Every stage of fcc sits behind an interface or a registry (`src/core`), and the
stock compiler is a set of default extensions (`src/ext`). The front end is
written once and never revisited; the expensive half — emitting machine code,
writing objects, linking — is the part that is swappable, so a new backend,
target or input language is an extension rather than a fork. Phase 2 validates
the front end as text assembly against three independent oracles; phase 3
assembles that text in-process to machine code (`src/masm`, byte-identical to
GAS output) and writes COFF (`src/coff`) and ELF (`src/elf`) objects. Nothing
is trusted without a cross-boundary test: a calling convention or data layout
that is wrong in a way two fcc-compiled functions agree on is invisible to any
test that never leaves the compiler.
