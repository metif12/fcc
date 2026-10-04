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

### Phase 2 — assembly-text backend

Port chibicc's `codegen.c` (43,920 B of C, 1,595 lines) behind `backend.Emit`. **Done.**

`src/backend/asm.v` is the text emitter behind `Emit` and everything about where
things live: addressing, loads and stores, the comparison and conversion tables,
the psABI's register classification, frame layout, and the data section with its
relocations.

`src/backend/gen.v` is the other half — the value-stack walk over the statement
tree: `gen_expr` and `gen_stmt`, the prologue and epilogue, the call sequence and
its argument classification, the variadic register save area, the VLA allocator,
and the bitfield extract and merge. The whole of codegen.c is now in V.

**Two of chibicc's data directives are wrong for this target and were replaced.**
`.local` and `.type x, @object` are ELF spellings that GNU as rejects here, with
`unknown pseudo-op` and `junk at end of line`. A symbol with no `.globl` is
already local, and COFF takes an object's size from its symbol table.

**Verified by running it.** Five programs are assembled by GNU as, linked by gcc
and executed, each returning 0 only if it computed the expected value: integer
arithmetic in a loop, `switch` with a case range, a backward `goto`, array
indexing through a parameter, struct assignment and return, bitfield
read-modify-write, and floating-point division and multiplication. tcc was run
over the same expressions so the expected values are C's rather than this
implementation's.

**Known, and the next things to fix.** Two front-end defects surfaced by running
the generator over tcc's own `stdio.h`: a diagnostic from an included file is
reported against the *including* file's path and line, and the arity of the
`getwchar` builtin macro is mis-evaluated. Neither is worked around in the
generator. `.loc` directives are not emitted, so the objects carry no line
information yet.

**Acceptance: the chibicc test suite passes**, adapted to invoke `vcc -S` then
`gcc`. This is the strongest correctness signal available anywhere in this
project — it compares runtime behaviour against gcc, not text.

**The suite is wired up and running. 8 of 18 files compile, assemble, link and
execute; 10 fail, each on a real defect.** The runner reads the 18 test files from
`rui314/chibicc` at `test/`, runs `vcc -S`, assembles with GNU `as`, links with gcc
against the suite's own `common`, and executes.

The blocker that stopped everything was a `.eof` sentinel (D33), fixed. The four
defects behind it, in the order a shape matrix found them:

- **`alloca` was never created.** `declare_builtin_functions` existed and nothing
  called it, so every VLA in every file read through a nil pointer in the backend.
  Fixed, along with `.vla_ptr` being typed as the array instead of the pointer, and
  `new_alloca` pre-setting a type that stopped `add_type` from typing its argument.
- **Adjacent string literals were not joined** (C11 6.4.5p5), and `expect` reported a
  missing token without consuming it. Together: an unbounded loop of diagnostics that
  ended in a garbage-collection abort on `control`, `string` and `struct`. Both fixed;
  three garbage-collection aborts became three syntax errors, which are tractable.
- **`sizeof ("a", "b")`** — `sizeof` of a parenthesised expression does not allow a
  comma expression, so `(1,2,3)` fails.
- **Compound literals and statement expressions** — `({ struct {int a;} x={1}, y={2};
  (x=y).a; })` needs an anonymous struct declaration inside a statement expression, and
  an assignment used as a value.

**Failing now: 8 of 18.** Four are one construct each and four are larger. Each was
narrowed to a minimal reproducer before being recorded here, because the suite itself
is the regression test and a table is not.

| file | what it needs |
|---|---|
| `control:94` | `initializer element is not constant` — a constant-expression rule to widen |
| `literal:94` | **a line splice is not applied outside a string literal** |
| `alignof:33` | `_Alignof` of an expression rather than of a type name |
| `unicode:9` | `int π = 3;` — a UTF-8 identifier |
| `union:13` | an anonymous struct member inside a `union` |
| `vla:22` | `sizeof(char[2][n])` — a VLA in a type name, whose size is a run-time value |


**`macro.c` needed its fixtures before it could be read at all.** `include1.h` through
`include4.h` are in the suite's directory on GitHub and were simply never fetched, so the
file failed at its second `#include` and nothing past line 2 was being tested. With them
present it reaches line 333.

What line 333 needs is an include whose *spelling* comes from a macro:
`#define M13 < include4.h` then `#include M13 >`. The directive's own tokens are `<`,
`include4`, `.`, `h`, `>`, and the expansion has to happen before the spelling is read.

The two errors after it — `M14()` at lines 347 and 350, a variadic macro called with no
arguments — are **not** a variadic-argument bug, and I was wrong about that twice before
measuring it. `#define NOTHING(...) 3` with `NOTHING()` expands to `3`, and so does the
same call nested as another macro's argument: both give `assert(0, 3)`, which is what tcc
gives. So either the `M14` errors are downstream of the failed include at 333 leaving the
preprocessor mis-positioned, or they are a third thing; that is untested, and the honest
entry is "one known defect and one unexplained pair".

The tempting repair — treating `...` as one parameter less when checking the argument
count — is wrong here, because `parse_params` deliberately leaves `...` out of `params`
and records it as the variadic flag. Subtracting one made `want` negative for a
pure-variadic macro and indexed `args[-1]`. That is why `want` is `params.len`.

Four fail to compile. The other fourteen compile, and every one of them fails the
same way, at its first assertion, for one reason.

**The line splice is the interesting one, and it is a design decision rather than a
bug.** `int size\` / `of(char);` must lex as the single identifier `sizeof`, and it
lexes as two. The tokenizer applies a splice inside a string literal, where a test
covers it, and nowhere else. C deletes backslash-newline in *translation phase 2*,
before anything is tokenized, which is why a splice can join the two halves of an
identifier — and why it cannot be handled by a scanner that reads one character at a
time.

The fix C specifies is to strip the splices once, in one place, before the tokenizer
runs, carrying a line number per output byte so diagnostics still point where they did.
Handled per-scanner instead, it means teaching the identifier, number, character and
punctuator scanners four variants of the same rule, and the fourth is the one that will
be wrong.

**The remaining thirteen are one bug, and it is the calling convention.** Every one of
them fails the same way, at the first assertion, with a garbage pointer where `assert`'s
third argument should be. `printf("noargs\n")` in a vcc program crashes with an access
violation. The generated call sequence is SysV AMD64:

```
  lea printf(%rip), %rax
  pop %rdi
  mov %rax, %r10
  mov $0, %rax
  call *%r10
```

Arguments in `%rdi`/`%rsi`, no shadow space, `mov $0, %rax` for the vector-register
count. Windows x64 is the Microsoft ABI: integer arguments in `%rcx`/`%rdx`/`%r8`/`%r9`,
floats in `%xmm0`–`%xmm3`, **32 bytes of shadow space the caller must allocate**, every
vector argument mirrored into its GPR, and the fifth integer argument on the stack rather
than in a fifth register. mingw's `printf` follows that, so every call vcc makes into the
C library is wrong.

**Why 264 tests and five working programs did not catch it.** Every call in those was
between two vcc-compiled functions. Both sides use the same wrong convention, so the
arguments land in the same wrong registers and the answer comes out right. The bug is
invisible from inside the compiler and invisible from any test that does not cross the
boundary to a library — which is to say invisible until a real program calls `printf`.

The recorded target ABI in this file — `long` 4, `long long` 8, pointers 8, `sizeof(void)`
1 — was measured correctly, and it is *data layout*. The calling convention was never
measured, because measuring it requires linking against something that was not compiled
by vcc. That is the gap, and the suite exposed it by being the first thing in the project
that crosses the boundary.

**What this means for the phase.** No front-end work will move these thirteen. The next
piece of work is the calling convention, and it is a single well-specified change:
register assignment, the shadow space, the GPR mirrors, and the stack argument placement.
`-m32` is not needed to find it — it is one convention to replace, in `classify_args`,
`push_args` and `gen_funcall` — and doing it against tcc's own output is the check, since
tcc on this host already uses the Microsoft ABI.

Until then, the honest statement of where phase 2 stands is: **four files fail to compile,
thirteen compile to code that cannot call anything.** The earlier framing — thirteen files
"computing the wrong answer" — was wrong, and it was wrong because it credited the
compiler with producing an answer at all.

**One acceptance criterion has to be restated.** The suite's expected values are
chibicc's, written for the Linux target it runs on, and two of them cannot both hold
with tcc on this host:

| | vcc | tcc here | chibicc's suite |
|---|---|---|---|
| `sizeof(L"ab")` | 8 | 6 | 8 |
| `sizeof(long double)` | 8 | 8 | 16 |

Both are `wchar_t` and x87 `long double`, and both are a Windows-versus-ELF ABI
difference, not a defect in either compiler. A file that disagrees only on those is a
**PASS with a recorded divergence**, not a failure. The comparison has to be against
tcc on this host, per assertion, rather than against the suite's literals — which
means the runner needs to compare answers rather than exit codes, and that is the next
piece of work.

**Acceptance for this phase is met when all 18 run, and every divergence from tcc
here is either fixed or recorded as an ABI difference.**
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


### The Windows x64 calling convention, measured

Recorded from mingw gcc 15.2 `-S -O0` on this host, because the implementation should be
written against these instructions rather than against a recollection of the ABI. Three
points differ from what the code generator currently does, and the third corrects
something committed earlier in this phase.

**Integer and pointer arguments go in `%rcx`, `%rdx`, `%r8`, `%r9`** — not `%rdi`, `%rsi`,
`%rdx`, `%rcx`, `%r8`, `%r9`. Measured for `add3(1,2,3)`:

```
	movl	$3, %r8d
	movl	$2, %edx
	movl	$1, %ecx
	call	add3
```

**Floating-point arguments go in `%xmm0`–`%xmm3`**, with no GPR mirror for a
non-variadic call. Measured for `dadd(1.0, 2.0)`:

```
	movapd	%xmm0, %xmm1
	call	dadd
```

**There is no `%al` vector-register count, and no per-call `sub` for the shadow space.**
gcc allocates the 32 bytes once in the prologue (`subq $56, %rsp` — 32 of shadow, 24 of
locals), so the shadow area is part of the frame rather than something each call site
re-establishes. Measured for a variadic `printf("%d %s\n", 42, "hi")`:

```
	leaq	.LC1(%rip), %rax
	movq	%rdx, %r8
	movl	$42, %edx
	movq	%rax, %rcx
	call	printf
```

No `mov $2, %al`. That instruction is a SysV requirement for the callee's register save
area and has no meaning here, so emitting it costs nothing but expecting it does.

**A `long double` variadic argument is passed by address, not in two stack slots.** This
corrects the earlier fix in this phase, which sized the outgoing argument area from the
number of stack *arguments* and let a `long double` occupy two of them — which is the
SysV shape and the reason `function.c` reported a value left on the stack. On this target
there is no x87 stack argument at all:

```
	fldt	.LC2(%rip)
	fstpt	-16(%rbp)
	leaq	-16(%rbp), %rax
	leaq	.LC3(%rip), %rcx
	movq	%rax, %rdx
	call	printf
```

The value is spilled to the frame, its *address* goes in the next GPR, and there is no
`%al`. So the slot-counting fix is not wrong arithmetic — it is arithmetic for the wrong
convention, and it will be replaced rather than kept. The diagnostic it produced was real
and the depth accounting it rested on will have to be redone against these rules.

**`%rdi` and `%rsi` are caller-saved on Windows**, where SysV makes them callee-saved. The
code generator uses both across argument setup, so the prologue has to save them if a
call can happen between their definition and their use.

**What this replaces.** `classify_args` decides the register class, `push_args` lays out
the argument area and `gen_funcall` loads the registers, and the callee side is
`create_param_lvars`' frame offsets plus `store_gp`/`store_fp`. All four read from the
SysV tables at the top of `gen.v`. The register lists are the whole change for the common
case; the shadow space, the `%al` removal and the by-address `long double` are the rest.

**The check is differential against tcc, which already uses this ABI on this host**, and
the first acceptance test is the smallest one that crosses the boundary: a vcc program
that calls `printf` and prints one line. It currently dies with an access violation, and
that program is the test.

