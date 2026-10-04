# Plan

## Goal

`vcc` replaces the bundled TinyCC that `vlang/v` uses as its default C backend on
Windows, so that the dependency becomes pure V and is built from V source like the
rest of the toolchain.

## Strategy: two stages behind one interface

The expensive half of this project is the part with no reusable implementation —
emitting machine code, writing objects, and linking. The cheap half — the C front
end — is largely a port of chibicc.

So the code generator sits behind the `backend.Backend` interface in
`src/backend/backend.v` from the first day:

- **Phase 2** implements it as text assembly. It is immediately testable, and it
  validates the entire front end against the chibicc test suite.
- **Phase 3** implements the same interface as a machine-code emitter, and adds an
  object writer behind it.

The front end is written once and never revisited. If phase 3 is abandoned, what
remains is still a working C compiler.

## Phases

### Phase 0 — contract capture *(in progress)*

Make the requirement falsifiable. `docs/CONTRACT.md` records the exact tcc surface
V depends on, each item quoted from a live source line.
`tests/contract/contract_test.v` asserts that V's source still contains those
items, so the contract cannot silently rot as V changes.

Also in this phase: `tools/harness`, the differential runner, which keeps
`PASS`, `FAIL` and `BLOCKED` strictly separate so a missing toolchain can never be
reported as a clean run.

**Done:** contract documented and pinned by 12 tests; harness with 15 tests.

**Remaining:** a corpus of V programs to compare `v.exe -cc tcc` against
`v.exe -cc vcc` on.

### Phase 1 — C front end

Reuse lemoncmd/vcc's skeleton, fill from chibicc.

Scope: **full C11, chibicc-style** (decision D15). Narrowing this to only what V's
codegen emits would be faster to reach, but it would reject the chibicc test suite
that phase 2 depends on for correctness.

- `src/vcc/tokenizer.v` — **done**: lexing, line splicing, both comment forms, every
  integer and floating base including hex floats, the full escape set, wide and UTF
  literals, and `#` lines captured whole for the preprocessor
- `src/vcc/preprocess.v` — **done**: `#define`/`#undef`, `#if`/`#ifdef`/`#ifndef`,
  `#elif`/`#else`/`#endif`, `#include` with the full search order, `#pragma once`,
  `#error`, `#line`, and macro expansion including `#`, `##` and the GNU variadic forms
- `src/vcc/expand.v` — **done**: phase-2 expansion with the recursion guard
- `src/vcc/cond_eval.v` — **done**: the `#if` expression evaluator
- `src/vcc/parser.v` — **done**: declspec, declarators, struct, union, enum, typedef,
  attributes, `typeof`, VLAs, initializers with designators, constant expressions,
  globals, and function bodies
- `src/vcc/stmt.v` — **done**: the statement and assignment grammar. `if`, `for`,
  `while`, `do`, `switch`/`case`/`default`, `goto` and labels, `break`, `continue`,
  blocks, local declarations, expression statements, `return`, the compound assignments
  and `++`/`--` lowerings, function calls with per-argument conversion, `_Generic`, and
  GNU statement expressions
- `src/vcc/types.v` — **done**: the type system measured against tcc rather than
  assumed — `long` is 4 bytes, `long long` and `long double` are 8, `size_t` is 8, and
  `sizeof(void)` is 1. Struct, union, **bitfields**, enum, typedef, function pointers,
  arrays, VLA, `const`/`volatile`/`restrict`, and the implicit conversions
- `src/vcc/eval.v` — **done**: constant expression evaluation, including the float
  forms `is_const_expr` has to fold, and the initializer byte writer
- `src/vcc/dump.v` — **done**: `--dump-ast`, which is the acceptance signal for this
  phase. It prints each global's layout, initial data and relocations, and each
  function's frame and statement count

`--preprocess` is the acceptance signal for the part that exists: it prints the token
stream after phase 1, so the front end can be validated on its own before any code
generation is attempted.

`-O` and `-W` selection flags are parsed and ignored; V only asks a compiler to
optimise under `-prod`, and then only for gcc/clang.

**Acceptance for the whole phase:** parse the whole corpus without crashing;
`--dump-ast` completes.

**Done:** the whole declaration and statement grammar, with 73 parser tests, 30
statement tests and 20 type tests. Every layout assertion is a byte image produced by
the bundled tcc rather than an expectation derived from the algorithm being tested.

**Remaining in this phase:** `asm` statements and compound assignment to an `_Atomic`
object are reported rather than translated; both need a node kind the backend has to
implement anyway.

### Phase 2 — assembly-text backend *(in progress)*

Port chibicc's `codegen.c` (43,920 B of C, 1,595 lines) behind `backend.Emit`.

**Done:** `src/backend/asm.v` — the text emitter behind `Emit`, and the half of
chibicc's generator that does not need the expression and statement state
machine. Addressing, loads and stores, the comparison and conversion tables, the
psABI's register classification, frame layout, and the data section with its
relocations. `vcc -S` writes it, and the output assembles: a global with an
initializer, a tentative definition in `.bss`, a string literal as its own object,
and a pointer into a table all round-trip through GNU `as` into a PE object.

**Two of chibicc's data directives are wrong for this target and were replaced.**
`.local` and `.type x, @object` are ELF spellings that GNU as rejects here, with
`unknown pseudo-op` and `junk at end of line`. A symbol with no `.globl` is
already local, and COFF takes an object's size from its symbol table.

**Not done:** `gen_expr` and `gen_stmt`, the value-stack walk over the statement
tree — roughly 1,100 of the 1,595 lines. A translation unit containing a function
definition is *reported*, not emitted with an empty body: an object that links and
does the wrong thing is the failure this project is least willing to accept.

**Acceptance: the chibicc test suite passes**, adapted to invoke `vcc -S` then
`gcc`. This is the strongest correctness signal available anywhere in this
project — it compares runtime behaviour against gcc, not text. It cannot run
until the expression and statement walk exists.

### Phase 3 — machine-code backend and COFF objects

- Replace `Emit.text` with `Emit.bytes`: an x86-64 instruction encoder written from
  the Intel manual, not from TCC.
- **RIP-relative addressing throughout** (decision D16), so `-shared` needs no
  second codegen path.
- A PE/COFF object writer: `.text`/`.data`/`.rdata`/`.bss`, symbol table,
  `IMAGE_REL_AMD64_*` relocations, and COMDAT selection groups. The last is not
  optional — V's generated C is full of `static` and `inline`, and a naive
  linker will either report duplicate symbols or silently pick the wrong one.

**Acceptance:** `lld-link` links vcc objects into a `.exe` that runs.

### Phase 4 — linker, imports, runtime

- A static COFF linker that resolves externals and emits `.reloc`
- Import libraries generated by parsing `thirdparty/tcc/lib/*.def` — the files are
  already in the V repository
- `-shared` producing a DLL with a real export directory
- Runtime: the four libatomic symbols `libgc.a` needs — `__atomic_fetch_add_8`,
  `__atomic_load_8`, `__atomic_or_fetch_8`, `__atomic_store_8` — each a single
  `lock`-prefixed instruction, plus `memcpy`/`memset` from msvcrt
- `tcc_backtrace` implemented in vcc (decision D17), walking frames with dbghelp

**Acceptance:** `v run <program>` works end to end.

### Phase 5 — wire into V

Add `vcc` to `V3CCompilerSelection` and to the tcc-family name matching in
`v3_is_tcc_compilation_failure`, and let it participate in the compiler-identity
hash that keys the object cache.

**Acceptance:** `./v -cc vcc -silent test vlib/v/` produces the same pass set as
`-cc tcc`.

### Phase 6 — Linux, then macOS

ELF writer and linker, then Mach-O. Deferred because `driver.v:347` records that
macOS TCC emits ELF objects that cannot link against clang's Mach-O — a real
cross-format problem that should not be discovered while three platforms are
already in play.

## Size estimate

| Component | Lines of V |
|---|---|
| front end | ~12,000 |
| assembly-text backend | ~2,000 |
| x86-64 machine-code encoder | ~6,000 |
| COFF writer | ~2,500 |
| COFF linker | ~3,500 |
| runtime and import libraries | ~1,000 |
| ELF writer and linker | ~3,000 |
| Mach-O writer | ~2,000 |
| **total** | **~32,000** |

This is a multi-month project. Phases 0 to 2 are roughly 15% of the work and about
90% of the validation, which is the argument for doing them first.

## Open questions

**None blocking.** The four questions raised before this phase were answered and
recorded as D15–D17; two of them turned out to be answerable by measurement and are
recorded as corrections C1 and C2. See `notes/DECISIONS.md`.

The following are noted for later and are not needed yet:

- **Bootstrap order.** `makev.bat` builds V with `-cc tcc.exe`, so the first `vcc`
  is built by the existing V+tcc and `-cc vcc` only becomes selectable in phase 5.
  No circularity; it merely fixes the order.
- **`-prod` never selects tcc** (`driver.v:7766`), so `vcc` inherits that
  limitation. Worth revisiting only if vcc turns out fast enough to change.
- **macOS in-process linking.** Phase 6 must decide whether to provide a
  `libvcc` with a `tcc_new`/`tcc_compile_file` API, or keep using the
  executable-based linker there. On Windows this is settled: `link.v` invokes the
  linker as a subprocess, so nothing extra is needed.

## Risks, ranked

1. Object writer and linker correctness (COMDAT, relocations) — no reference
   implementation under a permissive licence, and the failure modes are subtle.
2. `tcc_backtrace` correctness. A backtrace that faults while reporting a fault is
   worse than none. It sits late in phase 4 for that reason.
3. Bitfield layout, in both the type system and the object writer.
4. The rest of the runtime helper set, beyond the four libatomic symbols now
   measured. Still to be enumerated by linking V's output and reading the errors
   rather than guessing.
