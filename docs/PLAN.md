# Plan

## Goal

`fcc` replaces the bundled TinyCC that `vlang/v` uses as its default C backend on
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
`v.exe -cc fcc` on.

### Phase 1 — C front end

Reuse lemoncmd/fcc's skeleton, fill from chibicc.

Scope: **full C11, chibicc-style** (decision D15). Narrowing this to only what V's
codegen emits would be faster to reach, but it would reject the chibicc test suite
that phase 2 depends on for correctness.

- `src/fcc/tokenizer.v` — **done**: lexing, line splicing, both comment forms, every
  integer and floating base including hex floats, the full escape set, wide and UTF
  literals, and `#` lines captured whole for the preprocessor
- `src/fcc/preprocess.v` — **done**: `#define`/`#undef`, `#if`/`#ifdef`/`#ifndef`,
  `#elif`/`#else`/`#endif`, `#include` with the full search order, `#pragma once`,
  `#error`, `#line`, and macro expansion including `#`, `##` and the GNU variadic forms
- `src/fcc/expand.v` — **done**: phase-2 expansion with the recursion guard
- `src/fcc/cond_eval.v` — **done**: the `#if` expression evaluator
- `src/fcc/parser.v` — **done**: declspec, declarators, struct, union, enum, typedef,
  attributes, `typeof`, VLAs, initializers with designators, constant expressions,
  globals, and function bodies
- `src/fcc/stmt.v` — **done**: the statement and assignment grammar. `if`, `for`,
  `while`, `do`, `switch`/`case`/`default`, `goto` and labels, `break`, `continue`,
  blocks, local declarations, expression statements, `return`, the compound assignments
  and `++`/`--` lowerings, function calls with per-argument conversion, `_Generic`, and
  GNU statement expressions
- `src/fcc/types.v` — **done**: the type system measured against tcc rather than
  assumed — `long` is 4 bytes, `long long` and `long double` are 8, `size_t` is 8, and
  `sizeof(void)` is 1. Struct, union, **bitfields**, enum, typedef, function pointers,
  arrays, VLA, `const`/`volatile`/`restrict`, and the implicit conversions
- `src/fcc/eval.v` — **done**: constant expression evaluation, including the float
  forms `is_const_expr` has to fold, and the initializer byte writer
- `src/fcc/dump.v` — **done**: `--dump-ast`, which is the acceptance signal for this
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

**Acceptance: the chibicc test suite passes**, adapted to invoke `fcc -S` then
`gcc`. This is the strongest correctness signal available anywhere in this
project — it compares runtime behaviour against gcc, not text.

**The suite is wired up and running. 8 of 18 files compile, assemble, link and
execute; 10 fail, each on a real defect.** The runner reads the 18 test files from
`rui314/chibicc` at `test/`, runs `fcc -S`, assembles with GNU `as`, links with gcc
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

**Failing now: 10 of 18.** Eight compile, assemble, link and run green — `builtin`,
`compat`, `control`, `enum`, `generic`, `offsetof`, `union`, `vla`.

**Nine of the ten are not defects.** Every one was opened with `tools/onefile.v`, which
runs one suite file through the whole procedure and prints *all* of its stdout, because
`suite.v` reports five trimmed lines and that is not enough to find a failure: the
suite's `assert` prints one line per **passing** assertion and a differently-shaped line
for the failing one, so the last line printed is the last *pass* before it, never the
failure. Reading five lines off `suite.v` put me on four wrong hypotheses before that
tool existed. `v run tools/onefile.v <name.c>` and it takes the suite, fcc and gcc paths
as further arguments, which is also how a build from `HEAD` is run for a comparison.

| file | reported failure | cause |
|---|---|---|
| `arith` | `sizeof ( 0 ? ( long ) 1 : ( long ) 2 ) => 8` | `long` is 4 here |
| `literal` | `sizeof ( 0L ) => 8` | `long` is 4 here |
| `string` | `sizeof ( L"abc" "" ) => 16` | `wchar_t` is 2 here |
| `struct` | `sizeof ( struct { char a ; long b ; } ) => 16` | `long` is 4 here |
| `alignof` | `_Alignof ( long ) => 8` | `long` is 4 here |
| `bitfield` | `sizeof ( struct { long x : 1 ; } ) => 8` | `long` is 4 here |
| `unicode` | `sizeof ( L'0' ) => 4` | `wchar_t` is 2 here |
| `pointer` | `*( & x + 1 ) => 5` | chibicc's frame layout; gcc 15.2 and tcc fail it too |
| `function:96` | `__va_area__` | chibicc's private save-area name; decision below |

`types.v:19-24` records `long 4 / 4 (chibicc: 8 / 8)` and `types.v:642-643` records
`wchar_t` 2 against System V's 4, both as deliberate — the compiler has to agree with the
mingw objects it links against, not with chibicc. So these nine fail *correctly*, and the
only way to make them pass is to break every `long` in V's generated C.

**`macro.c` is the only genuine defect left, and it is in the preprocessor.** Its
remaining errors are all mechanical, none of them an ABI question:
`##` pastes whole argument lists instead of the two boundary tokens (lines 257, 261,
264, 267), stringification merges into one identifier (`f0 zz`, line 385), and five
builtins are missing — `__STDC__`, `__DATE__`, `__TIME__`, `__TIMESTAMP__`,
`__BASE_FILE__` — plus `__VA_OPT__` (C23) is unsupported.

Measured on the `##` one, because it is the kind of thing that gets mis-attributed:
`#define i 5` then `paste(1+i,3)` with `#define paste(x,y) x##y` produces the single
token `1+i3`, where C pastes only the *boundary* — the last token of `x` with the first
of `y` — giving `1`, `+`, `i3`. A build from `HEAD` produces the identical wrong token,
so this is pre-existing and not a regression from the interleaving change. It was
invisible before that change only because the whole file failed at line 333 first.

`control:94`, `literal:94`, `vla:22`, `generic`, `union:13` and `macro:333` were on this
list and are now fixed. `control` was `initializer element is not constant` and `macro`
was two defects; both are below.

**`control:94` was a label used as a value in a static local's initializer.**
`static void *p[] = {&&v41,&&v42,&&v43}` is a GNU extension and a legal constant
expression: a label's address is fixed before the program starts, exactly as `&g` is. The
byte image was being written while the initializer was still being parsed, and `&&v41`
carries no label until `resolve_goto_labels` matches it — which runs after the *whole*
body has been read. So the evaluator answered "not a constant".

The fix splits `gvar_initializer` in two. The **parse** stays where the initializer is
read, because that is also where `static int x[] = {1,2,3}` learns its length from the
braces and a later declaration indexing `x` depends on it. Only the **byte image** is
deferred, to a `flush_static_inits` after `resolve_goto_labels`. `eval2` returns the
node's `unique_label`, and `has_label` is tied to that being non-empty rather than to the
node's kind — so an *unresolved* `&&x` is still reported as "not a constant" instead of
becoming a relocation to an empty symbol name, which no assembler diagnoses usefully.

Measured, not argued: **before** the fix `control.c` failed at fcc -S with
`initializer element is not constant` at lines 94, 95 and 96; **after** it passes, and the
emitted assembly gives `{&&v52,&&v52,&&v53}` two references to one label and three
distinct labels for `{&&v41,&&v42,&&v43}`. The deferral is scoped to static locals
because a label belongs to the function it appears in, so a file-scope global can never
name one.

**`unicode.c` now fails on the right answer.** It asserts `sizeof(L'0') == 4`, which is
chibicc's System V `wchar_t`. This target's is two, and tcc, mingw gcc 15.2 and the
project's own ABI rule all say two — the same decision already made for `long` being four
bytes. The file was failing before the wide-literal work too, for other reasons; it now
fails on its first assertion, which is a strictly better failure and not a regression.

**`pointer.c`'s remaining failure is chibicc's frame layout, not arithmetic.**
`*(&x + 1) => 5` reads the integer *after* `x` in a statement expression, so it needs `x`
and `y` laid out adjacently in that order. gcc 15.2 answers `2061499264` and tcc `1441520`
for that exact statement — all three fail it, so the expectation is a chibicc coincidence
and not a portable one. The arithmetic around it, `*&x` and `**z`, do pass.

Re-measured 2026-10-09: three runs of the same statement gave `-801114008`,
`-570426200` and `1132460008` under fcc. **The value is a different stack slot each
run**, which is what confirms the reading above: the arithmetic is right and the object
it lands on is wherever this compiler happened to put the next local.


**`macro.c` needed its fixtures before it could be read at all.** `include1.h` through
`include4.h` are in the suite's directory on GitHub and were simply never fetched, so the
file failed at its second `#include` and nothing past line 2 was being tested. With them
present it reaches line 333.

What line 333 needs is an include whose *spelling* comes from a macro:
`#define M13 < include4.h` then `#include M13 >`. The directive's own tokens are `<`,
`include4`, `.`, `h`, `>`, and the expansion has to happen before the spelling is read.

The two errors after it — `M14()` at lines 347, 350, 363, 369 and `M31(buf, fmt, ...)`
called with three arguments at 406 and 407 — were recorded here as "one known defect and
one unexplained pair", with the guess that they were downstream of the failed include
leaving the preprocessor mis-positioned. **That guess was wrong, and the reason is the
most valuable thing in this file.**

`#include M13 >` never affects them. Measured with `--preprocess`: the include at 333
fails, and the tokens on lines 7 and 10 after it are still correct, and `M14()` on its
own still expands to `3`. The four `M14` shapes and `M31` all expand correctly in
isolation. Bisecting the file by truncation showed the 347 error appears only when lines
356-360 are present, which is the tell.

**A `#define` took effect retroactively over the whole file.** `Preprocessor.run` called
`directives(tokens)` — which consumes every `#` line and emits the rest *unexpanded* —
and then ran **one** `expand` pass over the entire accumulated stream. So every macro
definition in the file was already in the table when any of it was expanded:

```c
#define M(...) 3
int a = M();                              // expanded with the *second* definition below
#define M(x, ...) f(1,2,x,__VA_ARGS__)
int b = M(3,4,5);
```

reports `macro M requires 1 arguments, but 0 given` against the *first* line, leaves
`M()` unexpanded, and expands the second call correctly. `run_text` had the same shape.
[C11 6.10p7] is explicit: a directive takes effect from the point it appears.

**The same defect is what blocked `#include <stdio.h>` entirely.** mingw's own headers
carry `macro getwchar requires 0 arguments, but 1 given` on this compiler, because some
later definition of a function-like macro reached back to a call written against an
earlier one. That is fixed by the same change, and it is the one that unblocks real
programs rather than one suite file.

**The fix is to interleave, not to defer.** `directives` now holds a `pending` batch and
flushes it through `p.expand` at every directive and once more at the end, so a batch is
exactly the tokens between two directives and an invocation never spans one — which is
also what C requires, because a directive line cannot appear inside an argument list.
The outer `expand` in `run` and `run_text` is removed rather than kept: a second pass
would expand the names the recursion guard and a wrong argument count deliberately leave
in place, against whatever the file defined last, which is the original bug by another
route.

Four unit tests pin it at `src/fcc/preprocess_test.v` — a redefinition of the same name
from `(...)` to `(x, ...)`, a `#define` after a use, an `#undef` between two uses, and
the whole-file case. Three of the four go red against the broken flush, which is the
control that they are testing something.

**The tempting repair for the *unexplained pair* — treating `...` as one parameter less
when checking the argument count — would have been wrong twice over.** `parse_params`
deliberately leaves `...` out of `params` and records it as the variadic flag, so
subtracting one made `want` negative for a pure-variadic macro and indexed `args[-1]`.
And the pair was never an argument-count bug at all: it was the line at which the
expander chose to expand, which is why the diagnosis went in a circle for a whole
session. **A diagnostic whose line number points at code that is correct on its own
terms is evidence the diagnosis is aimed at the wrong thing.**

Four fail to compile. The other fourteen compile, and every one of them fails the
same way, at its first assertion, for one reason.

**The line splice was a design decision, and the decision was wrong.** `int size\` /
`of(char);` must lex as the single identifier `sizeof`, and it lexed as two. The
tokenizer applied a splice inside a string literal, where a test covered it, and nowhere
else. C deletes backslash-newline in *translation phase 2*, before anything is tokenized,
which is why a splice can join the two halves of an identifier.

The fix C specifies is to strip the splices once, in one place, before the tokenizer runs,
carrying a line number per output byte so diagnostics still point where they did. Handled
per-scanner instead, it means teaching the identifier, number, character and punctuator
scanners four variants of the same rule, and the fourth is the one that will be wrong.

**That is what was done, and the fourth did not get left wrong — but it is still the weaker
option and the reason is worth keeping.** Four scanners now step over a splice through one
shared `skip_splice`, and the token's *raw* span is kept for `loc` and `len` while only its
`text` is spliced out, so a diagnostic still points into the source as written:

| scanner | covers |
|---|---|
| `read_ident` | `size\<nl>of` is one identifier — the suite's case |
| `read_number` | `1\<nl>23` is one constant 123, `0x1\<nl>F` is 0x1F |
| `read_quoted` | `"spli\<nl>ced"` is one string, not a string plus two identifiers |
| `read_directive` | already folded splices, before this work |
| `read_punct` | a splice *at* the cursor, so `a \<nl>+ b` lexes `+` |

**The gap this leaves is a splice strictly inside a multi-character punctuator**: `+\<nl>+`
is two `+` tokens here and one `++` in C. Matching it means matching the table against a
spliced-out view of the source, which is the pre-pass above. No ordinary C writes that
spelling and none of the suite's 18 files contains it, so it is recorded rather than
silently relied upon. The pre-pass remains the right answer; it was not taken here because
it changes the meaning of every `loc` offset the preprocessor and `#line` resolution share.

The numeric half is why this was not treated as an identifier rule. `1\<nl>23` split into
two constants changes a program's arithmetic and names nothing, so it fails silently — a
strictly worse failure than the identifier one, which at least said
`undefined variable "size"`.

**The calling convention was the whole of it, and it is fixed.** All fourteen were
emitting psABI calls — `%rdi`, `%rsi`, no home area, a `%al` vector count — while mingw's
C library follows the Microsoft ABI. `printf("noargs\n")` died with an access violation
and every one of the fourteen printed a garbage pointer where `assert`'s third argument
should have been.

It was invisible for the whole of phase 2 because every call in the 264 unit tests and the
five working programs was between two fcc-compiled functions, which agree with each other
on the wrong convention. **A calling convention is only observable across a boundary**,
and nothing in the project crossed one until the suite did. The target ABI recorded
earlier in this file — `long` 4, pointers 8 — was measured correctly; it is *data layout*,
and the convention was never measured at all.

Fixing it took the suite from none passing to five: `builtin`, `compat`, `enum`,
`offsetof`, `union`. `function` assembles, links and runs for the first time. The nine
that run and fail now print real assertion values, so they are computing wrong answers
rather than failing to produce output at all — which is the next list, and it is ordinary
code generation rather than an ABI question.

**Open, and narrowed but not solved: stack arguments.** A call with one stack argument —
`printf(fmt, 1, 2, 3, 4)` — dies with an access violation, and `sum6(1,2,3,4,5,6)`
called from fcc to fcc returns the wrong answer. That second one matters: it means the
caller and the callee disagree *inside* fcc, so this is not an ABI question.

What is measured, so the next attempt does not repeat it:

| | first stack parameter | second |
|---|---|---|
| gcc's callee reads | `40(%rbp)` | `48(%rbp)` |
| fcc's callee reads | `40(%rbp)` — matches | `48(%rbp)` |

So `assign_lvar_offsets`'s `8 + shadow_space` is right, and the callee side is not the
fault. gcc's *caller* writes the arguments straight into their final slots —
`movl $5, 32(%rsp)` and `movl $6, 40(%rsp)` — without pushing anything, which is the
other structural difference: fcc builds the whole argument area on the stack and pops the
register arguments back out.

Pushing the stack arguments **left to right** makes a six-argument call read
`x=1=2=3=5=4` instead of `x=1=2=3=4=5` — a swap, so right-to-left is right and that
"fix" was a regression, reverted. Right-to-left still crashes with a single stack
argument, so the remaining suspect is the **alignment padding**: `push_args` emits its
`sub $8` *before* the pushes, which places the padding above the argument area where the
callee reads the first stack argument from. The next experiment is to place the padding
below the home area instead and see whether a one-stack-argument call survives; if it
does, the fix is to take the padding out of the frame rather than out of each call site,
which is what gcc does.

**Three of the nine running files are not defects at all.** `alignof`, `bitfield` and
`struct` fail on `_Alignof(long)` = 8 against 4, `sizeof(struct { long x : 1; })` = 8
against 4, and `sizeof(struct { char a; long b; })` = 16 against 8. All three are the
recorded Linux-versus-Windows difference: chibicc's `long` is eight bytes, tcc's on this
host is four, and fcc agrees with tcc. So the real count is **five** files computing a
wrong answer, not nine, and three of them are a divergence to record rather than to fix.

The other five wrong answers are ordinary code generation: `arith` on `++*p` through an
array pointer, `generic` on a `_Generic` selection of a `double`, `pointer` on `*(&x + 1)`
— which reads a neighbour the test happens to have placed there, so it is a test that
depends on the stack layout rather than on the language — `string` on the `\a` escape, and
`unicode` on stringizing a non-ASCII token, which is a consequence of this phase's own
decision to let 0x80-and-above bytes be identifier characters.

**`va_list` is 8 bytes on this target, and that is a decision, not a bug.** *(Superseded
by `docs/VARARGS.md`: the size was measured correctly but the *shape* was assumed from
the psABI and is wrong. It is a pointer, not the 24-byte tag below.)* Measured on
this host, both compilers agree:

```
$ gcc -o v.exe v.c && ./v.exe     # printf("sizeof(va_list)=%d", sizeof(va_list))
sizeof(va_list)=8
$ tcc -o t.exe v.c && ./t.exe
sizeof(va_list)=8
```

Not 24. It is not the SysV struct of `gp_offset`, `fp_offset`, `overflow_arg_area` and
`reg_save_area`; it is a **pointer** — the Microsoft form — and the register save area it
points at is a separate 176-byte object.

`emit_va_area` writes the 24-byte SysV struct, because that is what chibicc writes and
what `test.h` in the suite declares:

```c
typedef struct { unsigned int gp_offset; unsigned int fp_offset;
                 void *overflow_arg_area; void *reg_save_area; } __va_elem;
typedef __va_elem va_list[1];
```

so `function.c`'s `*ap = *(__va_elem *)__va_area__;` copies 24 bytes into what it then
passes to `vsprintf` — a function from `common`, built by gcc, whose `va_list` is 8 bytes.
**The suite's own test is internally inconsistent on this target**, and it only ever worked
because chibicc's `va_list` and chibicc's `vsprintf` agreed with each other.

That leaves two defensible answers, and no measurement picks between them:

- **Follow this host's ABI.** `__va_area__` becomes an 8-byte pointer to a 176-byte save
  area. Then a fcc-compiled program can pass a `va_list` to the real `vprintf`, and can
  read one that `vprintf` filled in. That is the property that matters for replacing tcc,
  and it is what "a C compiler on Windows" means. `function.c` would then fail, because it
  is testing chibicc's private convention rather than the platform's.
- **Follow the suite.** Keep the 24-byte struct. Then `function.c` passes and the suite
  goes further, at the cost of never interoperating with anything outside it — including
  V's own generated C, which includes the real `<stdarg.h>`.

The first is right for the project's premise and the second is right for the acceptance
criterion, and doing the first makes one of the eighteen files permanently unfixable.
Recorded here rather than decided alone.

**Separately, `function.c`'s failing assertion is now a `va_list` test at line ~100**,
where before the call-sequence fix it failed at line 4 with a garbage pointer. So this is
where the variadic *callee* side first became reachable.

**The `stdarg.h` on this target is tcc's, and it changes what has to be built.** Measured
on this host:

```c
typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_arg   __builtin_va_arg
#define va_copy  __builtin_va_copy
#define va_end   __builtin_va_end
```

No `__va_list_tag`, no `gp_offset` arithmetic in a macro — the whole convention is five
**compiler builtins**, which is why `sizeof(va_list)` is 8 and why nothing in it is a
struct. So the layout committed in `051812b` is right, but it is only half the answer: the
header is the one fcc will be asked to satisfy, because `-I` points at tcc's include
directory, and it delegates the entire mechanism to the compiler.

**What is therefore missing is five builtins**, and it is one piece of work rather than
five. *(Done — see `docs/VARARGS.md`. The four operations are as described below, but
the description of the tag they manipulate is superseded: there is no tag, and
`__builtin_va_copy` is an eight-byte pointer copy rather than a 24-byte structure
copy.)*

- `__builtin_va_start(ap, last)` — assign the address of the tag, which is already what
  `__va_area__` holds.
- `__builtin_va_arg(ap, type)` — the substantial one. It takes the address of `ap`, and
  the choice between the register save area and the overflow area depends on the *type*:
  a floating-point type compares `fp_offset` against the end of the SSE slots and steps by
  16, an integer type compares `gp_offset` and steps by 8, and either falls through to the
  overflow area once its register class is exhausted. Both the read and the update of `ap`
  happen in place, because `ap` is memory the caller keeps.
- `__builtin_va_copy(dst, src)` — a 24-byte structure copy, since the tag is that size.
  *(It is an eight-byte pointer copy. `va_list` is a pointer.)*
- `__builtin_va_end(ap)` — nothing.

chibicc implements these in the front end for the same reason: the type argument is a
compile-time type, so the whole offset computation is constant folding, and doing it in the
backend would mean an instruction-encoder-visible special case for a construct that has
none at run time. **Partial implementations are worse than none** — a variadic callee that
reads integers correctly and floats wrongly is far harder to diagnose than one that refuses
— so all four go in together. *(Done, and all four went in together. The stride is the
one thing the type decides, and it is 8, 16 or 8 depending on `sizeof(T)`.)*

**Until they exist, no end-to-end `vprintf` test can be written, and the layout in
`051812b` is a belief rather than a verified thing.** The differential test to write once
they do: a program using `vprintf`, compiled by fcc and by tcc, compared line by line. tcc
is on this host, uses this ABI, and is the better oracle for this subsystem than the suite.

**`function.c` lines 261 and 265 stay unfixable**, and the reason is now exact rather than
probable: `test.h` defines its own `va_list` as `__va_elem[1]`, twenty-four bytes, which
shadows the builtin one. `vsprintf` then receives a pointer to twenty-four bytes where it
reads eight, and reads `gp_offset` and `fp_offset` as an address. Nothing fcc emits changes
that, because the inconsistency is between the suite's declaration and mingw's library.

**The escape table: isolated to one line, and the table itself is exonerated.** The
minimal case needs no preprocessor, no macro, no `#`:

```c
int main(void) { return "\a"[0] == 7 ? 0 : 1; }
```

`tcc` exits 0. fcc exits 1. And the table is *not* the problem — the same declaration,
looked up the same way, in a standalone V program:

```v
const simple_escapes = { 'a': 7  'b': 8 }
c := `a`
println(c.str())                    // a
println(simple_escapes[c.str()])    // 7
println(simple_escapes[`q`.str()])  // 0
```

So `simple_escapes[c.str()]` works, the keys are one-character strings, and a missing key
gives 0 — which is exactly the "unknown escape yields the character itself" fall-through
that produces 97.

What has been ruled out, in order:

- **Not the `match` arms.** `\n`, `\t`, `\r`, `\\`, `\'`, `\"`, `\?` and every numeric form
  all decode correctly, and every one of them has an explicit arm in the `match` that runs
  *after* the table lookup. So the branch is reached and `decode_escape` is called.
- **Not the map key type.** Both spellings were tried; `simple_escapes[c]` is rejected by V
  with `expected string, not u8`, which says the map is keyed by string and `c` is what
  does not fit, while `simple_escapes[c.str()]` compiles.
- **Not the preprocessor, the stringize operator, or macro expansion.** The reproducer above
  has none of them.

That leaves the value the literal is given, not the escape: `read_quoted` builds `data`
correctly and assigns it to `str_data`, so the next thing to check is whether anything
between the tokenizer and the code generator **rewrites `str_data`** — `expand` copies
tokens, and `stringify` is the one place that is known to build a `.str_` token with its
value computed by a *different* routine (`string_body`, which strips quotes and undoes
escaping rather than decoding them).

An attempted fix for exactly that was made and **reverted**: replacing `string_body` with a
real decode made `\n`, `\"` and `\\` correct and left `\a` broken, and it made
`unicode.c`'s stringize render as an empty string. No verified improvement, one new symptom
— so it went back out rather than staying in on a plausible story.

**The wide-string prefixes carry Linux's widths.** Measured on this host, both compilers
agree:

```
$ tcc -o t.exe v.c && ./t.exe
sizeof(wchar_t)=2
sizeof(L'ab')=6        # three elements of two bytes
```

and chibicc's own suite expects `sizeof(u"abc" "def") == 14` — seven elements of two bytes
— which is the *same* number, so `string.c` and tcc agree here and **fcc is the outlier**:
`string_element_type` returns `ty_int` for `L`, `u` and `U`, four bytes each, so
`sizeof(u"abc" "def")` comes out 28.

So the widths to use on this target, from the measurements rather than from the Linux
convention:

| prefix | fcc now | this target | note |
|---|---|---|---|
| `L"…"` | 4 | **2** | `wchar_t` is 2 here, so `L` is 2 |
| `u"…"` | 4 | **2** | `char16_t` |
| `U"…"` | 4 | 4 | `char32_t`, the one that was already right |
| `u8"…"` | 1 | 1 | |

**One test encodes the wrong assumption and has to change with it:**
`test_a_wide_piece_decides_the_width_of_the_whole_run` asserts 16 for
`sizeof(L"ab" "c")`, which is four elements of four bytes. tcc answers 8. The test's own
comment already points at this, and it was written when the only oracle in hand was
chibicc's Linux-shaped expectations.

This is recorded rather than changed here because it is **data layout**, and the blast
radius of a prefix width is every `L`/`u`/`U` literal and every `wchar_t`/`char16_t` in the
program. The same care that went into `long` = 4 has to go in: change it, then check
`string`, `unicode` and the layout tests, and treat a `long`/`wchar_t`/`long double`
disagreement with the suite as a divergence to record rather than a defect to fix.

**A variadic call's floating-point mirror is indexed by argument position, not by
floating-point position.** [MS x64 3.2] passes a floating-point argument to a
variadic function in an SSE register *and* in the general register that its position
selects, because a variadic callee reads only the general-register copy. The
generator indexed the mirror by `fp` — the argument's position among the
floating-point ones — and a unit test asserted exactly that, so the two agreed.

It is wrong, and only a program that crosses into the C library can see it.
Measured on `printf("a=%g b=%s c=%d", 3.5, "hi", 7)`:

| | `%rcx` | `%rdx` | `%r8` | `%r9` |
|---|---|---|---|---|
| gcc | format string | 3.5 (mirror of `%xmm0`) | `"hi"` | 7 |
| fcc, before | **3.5** | `"hi"` | 7 | — |
| fcc, after | format string | 3.5 | `"hi"` | 7 |

fcc put the mirror in `%rcx`, overwriting the format string, so the program died
with `0xC0000005` and printed nothing at all. The boundary test is
`tools/suite`-style: one `printf` with a `double` in it, built by fcc, linked by
gcc, run, and compared with tcc. The unit test that "covered" the mirror asserted
a register that provably destroys its neighbour.

The same rule fixes a second, silent half: on a variadic call a floating-point
argument also consumes a general-register position, so it goes on the stack once
those are gone even though `%xmm` registers remain. Measured for
`printf("d=%g s=%s i=%d f=%g\n", 1.5, "hi", 7, 2.5)`, where 2.5 is the fifth
argument: gcc puts it in `%xmm0` *and* at `32(%rsp)`.

**Still failing to compile, four of eighteen:**

| file | what it needs |
|---|---|
| `control:94` | `initializer element is not constant` — a constant-expression rule to widen |
| `literal:94` | a line splice, which C deletes in translation phase 2 |
| `macro:333` | `#include M13 >`, where the spelling comes from a macro |
| `vla:22` | `sizeof(char[2][n])` — a VLA in a type name, whose size is a run-time value |

#**The variadic mechanism is now built, and the layout it was built on was wrong.**
`docs/VARARGS.md` has the measurements and the five defects found on the way; the
short version:

- `va_list` is **a pointer**, and the 24-byte `gp_offset`/`fp_offset`/`overflow_arg_area`/
  `reg_save_area` tag that `051812b` put in `src/ast/abi.v` is the psABI's, not this
  target's. Reading the bytes a callee's `va_list` addresses shows the *argument
  values*, in gcc's output as much as tcc's.
- So there is no tag and no register save area. The callee spills its four argument
  registers to the caller's own home area, which makes the register arguments and the
  caller's stack arguments **contiguous**, and `va_arg` is "read at `*ap`, add the
  stride". The four `__builtin_va_*` operations are what `<stdarg.h>` on this target
  reduces to in full.
- The `__va_area__` local and `va_area_size` are gone, replaced by
  `va_start_offset` and `va_slot` in `src/ast/abi.v`.

**Verified by running**, five programs in `tests/endtoend/`: `varargs.c`,
`va_start_offset.c`, `va_arg_stride.c`, `sum6.c` and `assign_convert.c`, each compiled by
fcc and by tcc and compared on stdout *and* exit code, identical. `varargs.c` includes a
case that hands a fcc-built `va_list` to mingw's `vprintf`, which is the part that cannot
be checked by two fcc-compiled functions agreeing with each other.

`tools/probe/probe.v` is the runner. It reads `tests/endtoend/` from the tree, so adding a
program there is enough to have it compared, and it needs two environment variables:

- `VCC_V_ROOT` — the V tree to take `thirdparty/tcc/tcc.exe` from.
- `VCC_PROBE_DIR` — a scratch directory for the `.s` and `.exe` it leaves behind. It is
  required rather than defaulted, because `join_path('', 'cmp')` is the *relative* `cmp`
  and the runner would quietly create it wherever it was started from — which is how the
  first version of this tool came to leave its output under `tools/probe/`.

**Three defects were pre-existing and had nothing to do with varargs.** Two were in the
way of the above and are fixed; one was measured, found not to be a defect, and left
alone. `docs/VARARGS.md` has the evidence for all three.

- `add_type` never converted an assignment's right-hand side to the left-hand side's
  type, so `double s = 0;` stored an integer zero through an SSE store. A program with
  no `va_arg` in it at all returned `3.7756e+150` where gcc and tcc return 7. Fixed.
- `push_args` counted one eight-byte slot per stack argument, so an aggregate pushed whole
  by `push_struct` left the caller's own cleanup short by `size / 8 - 1` and the program
  was refused with `function "main" left 3 values on the stack` — a diagnostic naming the
  stack rather than the argument that unbalanced it. Fixed, with a test that was seen to
  fail first.
- `get_common_type` returns `pointer_to(nil)` for an aggregate, and looked like it was
  making every struct 8 bytes wide. It was not: `long` is four bytes on this target, so
  the probe that "proved" it was written with `long` where it needed `long long`. The
  branch is also unreachable — all three callers are arithmetic contexts, which cannot
  receive a struct operand — and a version that returned the aggregate measured
  byte-identical. Reverted; an unreachable branch with a latent bug is a smaller problem
  than a reachable one.

**Two more pre-existing defects were found and are recorded, not fixed**, because both
belong to the aggregate ABI rather than to the variadic walk. `docs/VARARGS.md` gives the
reproductions. The larger one: an aggregate over two eightbytes is passed *by reference*
on this target — gcc emits `leaq -64(%rbp), %rax; movq %rax, %rdx` — and fcc's `va_arg`
reads the slot that way, but fcc's *caller* copies the bytes inline instead of passing the
address. The two halves agree with each other and with neither the platform nor the
oracle, which is why such a call access-violates where tcc answers correctly. Fixing it
means changing the convention on both sides for every struct-passing call in the compiler.

#**Five more defects, none of them about varargs, and two of them severe.**

Found by asking the oracles what a shape is worth rather than by reading the code. All
five are fixed; all five are measured against tcc and gcc; the two largest have controls
below.

**A nested array declarator was built backwards.** `int a[3][5]` is three rows of five, so
the suffixes apply right to left. They applied left to right, which builds
`array(array(int, 3), 5)`.

The two differ in a total size and in nothing else a self-consistent program looks at —
same product, same innermost stride, and `a[i][j]` reads and writes through the same
reversed shape, so **every value came back right**. Two things noticed it, and both are
now in `tests/endtoend/array_layout.c`:

| | tcc | fcc before |
|---|---|---|
| `&a[1] - &a[0]` | 20 | 12 |
| `sizeof(*a)` | 20 | 12 |
| `int b[2][3][4]`, `&b[1] - &b[0]` | 48 | 24 |
| `&b[0][1] - &b[0][0]` | 16 | 8 |

This is the worst of the five, because a *pointer to the row type* is exactly what crosses
a compiler boundary. `int (*pa)[5] = a` then `pa` was reading a struct layout that no other
compiler shares, and nothing inside fcc could ever see it.

**A plain binary `+` or `-` on a pointer was never scaled.** [C11 6.5.6p8] `p + n` is
`p + n * sizeof(*p)`. `q[1]`, `q += 1` and `q++` all scaled — those paths go through
`new_add` — and only the plain operator built its node directly and ran the *usual
arithmetic conversions* on it. So `int *q; q + 1` advanced one byte whatever the element
type: four for an `int`, eight for a `double`, one for a `char`, where only the `char` was
right and only by accident. `q + 1` and `q[1]` disagreed with each other by a factor of
four inside one expression. This was the recorded `pointer.c` failure.

Fixed by routing `additive()` through `new_add`/`new_sub`, which is where chibicc puts it.
The scaling lives in those two builders rather than in `add_type` because `add_type` is a
free function with no access to the node builders, and because it is idempotent — a node
that already has a type is left alone, so a second `add_type` cannot scale twice.

**A pointer to a VLA stepped by the placeholder width.** `vla_of` gives every VLA an
eight-byte `size`, because the extent is not known until the declaration runs. For
`int x[n + 1][n + 6]` — both extents variable, so the row is *itself* a VLA — `x[i]` scaled
by that eight, and `x[1][0]` returned `2` where it must be `16`. `pointee_size` now reads
the element's own size local when the element is a VLA, which is what the declaration
already computed.

**A wide literal was typed at twice the width.** `L` and `u` were four bytes per element
because chibicc is System V. Measured on this host:

| | tcc | gcc | fcc before | fcc now |
|---|---|---|---|---|
| `sizeof(L"ab")` | 6 | 6 | 12 | 6 |
| `sizeof(L"ab" "c")` | 8 | 8 | 16 | 8 |
| `sizeof(L'a')` | 2 | 2 | 4 | 2 |
| `sizeof("ab")` | 3 | 3 | 3 | 3 |

`U` is four here and `u8` is one, which is what C11 6.4.4.4 says; tcc rejects `u"`, `U"`
and `u8"` outright, so those three are gcc's answer alone. This is the same decision as
`long` being four bytes: follow the host, not chibicc.

It was worse than a wrong `sizeof`, because the *storage image* was already right —
`string_initializer` takes the stride from the declared array, not from the literal — so
fcc wrote `61 00 62 00 00 00` and then declared the object sixteen bytes wide.

**`sizeof` of a type name containing a VLA.** Only a bare VLA was handled; an array of one
answered `array_len * 8`, the placeholder, so `sizeof(int[n][5])` was 40 where it is 100.
And a bare VLA fell through to an untyped `.generic` node that the backend reached as
`gen_binary` with a nil left operand, which is the suite's recorded
`operator with no left operand at line 22` — a diagnostic naming the arithmetic rather
than the type that could not be sized. All three shapes now match tcc exactly, and
`vla.c` **passes**.

### The controls

Neither the array-order fix nor the pointer-scaling fix is believed because the tests are
green. Both were reverted and the suite run again:

| reverted | unit tests | cross-boundary probe | chibicc suite |
|---|---|---|---|
| nothing | 9 passed | 9 of 9 match | **6 of 18** |
| suffixes left to right | **1 failed** | `array_layout`, `vla_size` DIFFER | — |
| plain `+` unscaled | — | `array_layout`, `va_start_offset` DIFFER | 6 of 18 |

`vla.c` is the suite file that went from failing to passing, so the suite is **6 of 18**
and not 5. The five that already passed still pass.


**The suite is at 6 of 18**, the six listed in `tools/suite/suite.v`'s own output and the
twelve still recorded above. `vla.c` is the one that moved; the five that already passed
still pass, and nothing regressed. `function.c` still fails at compile time on
`undefined variable "__va_area__"`, because the suite declares its own 24-byte `va_list`
and reads the local the variadic work removed.

## The Windows x64 calling convention, measured

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
the first acceptance test is the smallest one that crosses the boundary: a fcc program
that calls `printf` and prints one line. It currently dies with an access violation, and
that program is the test.

## Open defects, recorded rather than worked on

Two were found by exercising real programs against the boundary, and neither is
worked on here. Each has a reproducer, because an open defect without one is a
story rather than a bug.

**A vcc-compiled comparator passed to libc's `qsort` hangs.** The reproducer is a
call whose four arguments are a base pointer, a count, an element size and a
function pointer:

```c
#include <stdlib.h>
int cmp_ext(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
int main(void) {
  int a[5] = {5, 3, 1, 4, 2};
  qsort(a, 5, 4, cmp_ext);
  printf("done\n");
}
```

gcc answers `done`; fcc exits `-1073741819` (access violation), or hangs when the
comparator returns a constant. The stack ordering of the four arguments is
correct — the address, the count, the size, then the comparator — and the
comparator *is* reached, so this is inside the callback or inside what libc
expects of it, and not a marshalling failure. Established by isolating it: the
same call with a null comparator returns, and with a one-element array qsort
never calls the comparator at all, so a shape that avoids the call also avoids
the fault. A twelve-block program built out of individually-correct blocks hangs
too, which is the same defect through a longer path.

**A wide bitfield produced assembly GNU `as` rejected outright.** A field wider
than an int needs the mask `(1 << 40) - 1`, and the generator emitted it as
`and $1099511627775, %rdi`. `and` only accepts a sign-extended 32-bit immediate,
while `mov` takes the full width — which is what `movabs` is for. GNU `as`
refused the whole translation unit with `operand type mismatch for 'and'`, so
this shape did not compute wrong, it did not assemble. Measured: the same
program with a 4-bit field was fine, which is what made the wide one invisible.

The mask is staged through a caller-saved register now, so the `and` is between
registers. `tests/endtoend/bitfield_wide.c` covers it, and the broken version
still produces the assembler error, which is the control.
