# The variadic builtins, and what this target actually does

Measured 2026-10-06 on this host, against mingw gcc 15.2 and tcc 0.9.28rc, which
agree on every shape below. The tcc builds used tcc's own `include/` directory; the
fcc builds were given the same directory with `-I`, because fcc has no built-in
include path and a probe that fails on `#include <stdio.h>` measures the include path
rather than the compiler.

## The `<stdarg.h>` on this target delegates everything to the compiler

The whole file is twelve lines:

```c
typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_arg   __builtin_va_arg
#define va_copy  __builtin_va_copy
#define va_end   __builtin_va_end
```

No `__va_list_tag`, no `gp_offset` arithmetic in a macro. So the four builtins *are*
the variadic mechanism, and `-I` points at this header, which is why they could not be
deferred past phase 2: V calls variadic functions.

## The `va_list` is a pointer, and the 24-byte tag that was committed is wrong

`sizeof(va_list) == 8` from both compilers. That part was measured. The *shape* was
assumed from the psABI, and it is wrong: `src/ast/abi.v` carried the SysV
`gp_offset`/`fp_offset`/`overflow_arg_area`/`reg_save_area` struct plus a 176-byte
register save area for the whole of phase 2.

The measurement that refutes it is a callee that dumps the bytes its `va_list`
addresses:

```
$ tcc -o t.exe walk.c && ./t.exe
before va_list bytes: 01 00 00 00 00 00 00 00 02 ... 03 ... 04 ...
                        ^ the argument values themselves
```

Not four header words — the arguments. gcc 15.2 produces the same bytes.

The mechanism is the Microsoft one, and it is three things rather than a structure:

| | |
|---|---|
| the callee spills `%rcx`, `%rdx`, `%r8`, `%r9` to `16/24/32/40(%rbp)` | the caller's own home area, so the register arguments and the caller's stack arguments are **contiguous** |
| `va_start(ap, last)` sets `ap` to the first slot past the named parameters | `lea 24(%rbp), %r10` for `int f(int n, ...)` |
| `va_arg(ap, T)` reads `T` at `*ap` and adds the stride to `ap` | no class arithmetic at all |

There is no register save area and no `%al`. A variadic callee never reads `%xmm`
through its `va_list`, because the caller mirrors every floating-point argument into
a general register.

### The three strides

Measured, both compilers agreeing:

| `sizeof(T)` | where the value is | stride |
|---|---|---|
| up to 8 | in the slot | 8 |
| 9 to 16 | in two consecutive slots | 16 |
| over 16 | the slot holds the **address** ([MS x64 2.2.5]) | 8 |

A `long double` takes the third path despite being 8 bytes here, because `classify_args`
passes it by reference.

## What was wrong on the way, and how it showed up

Five defects, all found by running a program rather than by reading the code. Each was
found *after* the layout was believed correct.

**`va_start` pointed one slot too low.** It is measured from the home area, which is
*below* `incoming_base`, so it adds the count of named register slots. A version that
pointed at the base itself re-read the argument `va_start(ap, n)` had already named.
A probe asking for six integers answered `1 9 17 25 33 41` instead of
`1 2 3 4 5 6` — eight bytes of drift per step, because the walk was moving through
addresses rather than values.

**`va_arg` wrote its advance to the wrong place.** The read dereferences the pointer
the `va_list` holds; the advance writes through the *address of the object*. With one
register for both, `addq $8, (%r10)` overwrote an argument slot and each read saw the
previous advance as its own value: the same `11 19 27 35 43 51` from a different
mistake. `%r11` now holds `&ap`; nothing else in the generator names it.

**`va_start` and `va_end` were expressions.** `va_start` is one store and `va_end` is
nothing, so neither produces a value, and this generator's contract is that every
expression leaves exactly one slot on the stack. A correct `va_start(ap, n);` failed
to compile with `function "sum6" left 1 values on the stack` — a diagnostic naming the
stack rather than the construct that caused it. They are parsed as statements now.

**An assignment did not convert its right-hand side.** This one is *pre-existing* and
has nothing to do with variadic arguments, but it was in the way: `double s = 0;`
stored an integer zero through an SSE store, so the slot kept whatever the frame held.
A program doing only

```c
double s = 0; s += 1.5; s += 2.5; s += 3.0; return s;
```

returned `3.7756e+150` under fcc and `7` under both gcc and tcc. Confirmed pre-existing
by building the commit before this work: same garbage. Fixed in `add_type`, which now
converts the right operand to the left operand's type — [C11 6.5.16.1], and the left
type is fixed because it is the object being stored into, so `usual_arith_conv` is the
wrong helper to reach for.

**The caller's stack accounting ignored an aggregate's size.** `push_args` computed the
size of the stack argument area by counting one eight-byte slot per argument, with a
special case for `long double`. An aggregate larger than two eightbytes is pushed by
`push_struct`, which reserves its whole size, so the caller's own cleanup was short by
`size / 8 - 1` and fcc refused to compile the program with `function "main" left 3 values
on the stack` — a diagnostic naming the stack rather than the argument that unbalanced
it. It now counts `align_to(size, 8) / 8`, which is what `classify_args` had been
reserving all along.

## A fifth defect, found while measuring, and not fixed

`get_common_type` falls through to `pointer_to(ty1.base)` for an aggregate, and a
struct's `base` is nil — so `pointer_to(nil)`, a pointer type of size 8. It was reached
from a `va_arg` of a 16-byte struct during this work, and the `size=8` that came back is
what made the three strides above look wrong.

It is not fixed, because it was not the bug it appeared to be, and this is the second
time in this project that a measurement was mistaken for a cause:

- `long` is **four** bytes on this target, so `struct S16 { long a; long b; }` is
  *legitimately* eight. The probe that "proved" every struct came out eight was written
  with `long` where it needed `long long`.
- `get_common_type` has exactly three callers — `usual_arith_conv` and two type
  comparisons — and none of them can receive a struct operand in valid C. The branch is
  unreachable, so it was changed to return the aggregate itself and the frame layout of a
  struct-passing program came out **byte-identical** to the commit before, measured.
- That version was then reverted. It returned `.array` and `.vla` *before* the decay
  rule three lines below it, which would have been wrong for the reachable cases in
  exchange for nothing.

An unreachable branch with a latent bug in it is a smaller problem than a reachable one,
and it is recorded here rather than patched.

## A sixth defect, in the caller's half of the aggregate rule, and not fixed

`va_arg` of an aggregate larger than two eightbytes dereferences the slot, because
[MS x64 2.2.5] passes such an argument *by reference*. gcc 15.2 agrees — for
`take(1, q, 30)` with a 32-byte `q` it emits `leaq -64(%rbp), %rax; movq %rax, %rdx`,
the address in the argument register, and `va_arg` reads `movq (%rcx), %rax` through it.

fcc's *caller* does not do that. `push_struct` copies the whole aggregate onto the stack
argument area, and `classify_args` reserves `align_to(size, 8) / 8` slots for it, so fcc
passes the bytes inline. fcc's reader and fcc's writer therefore agree with each other
and with neither the platform nor the oracle, which is why a `va_arg` of a 32-byte
aggregate access-violates where tcc returns the right answer:

```c
struct Q32 { long long a, b, c, d; };
struct Q32 q = {1,2,3,4};
take(1, q, 30);   // fcc: 0xC0000005   gcc, tcc: fine
```

It is pre-existing and has nothing to do with varargs — the same call through a
**non**-variadic parameter fails identically, so it is the aggregate ABI and not the
variadic walk:

```c
void h(struct Q32 s);
h(q);             // fcc: function "main" left 3 values on the stack
```

Fixing it means changing the convention on both sides — pass the address instead of the
bytes, one slot instead of `size / 8`, and have the prologue copy from it. That is a
change to every struct-passing call in the compiler, so it belongs with the pass that
owns aggregate layout, not with the varargs builtins.

## What is verified and what is not

**Verified by running**, `tests/endtoend/`, every program compiled by fcc and by tcc and
compared on stdout *and* exit code: `varargs.c`, `va_start_offset.c`, `va_arg_stride.c`,
`sum6.c` and `assign_convert.c`, all matching.

`varargs.c` is the decisive one: it passes a fcc-built `va_list` to mingw's `vprintf`,
which walks it according to the platform ABI and knows nothing about fcc.

```
sum6=21 sum3=60 dsum=7 str=hello dbl=3.25 i=77 forward: i=42 d=2.5 s=ok
first=one second=one sprintf=5/1.5
```

`va_start_offset.c` measures the stride `va_arg` advances and the value of the first
argument *past* the named ones, for four different shapes of named parameters. An earlier
version printed the address difference between `ap` and `&a` instead, which is not an ABI
fact: whether a named parameter is addressed in place or copied to a frame slot is the
compiler's own business, and this one copies, so the two compilers differ by a constant
that has nothing to do with varargs.

**Not verified:** every shape reachable only through `<stdarg.h>`, because the
recorded `getwchar` arity defect stops any program that includes it. The builtins are
spelled out directly in the end-to-end tests for that reason. The `va_arg` of an
aggregate over two eightbytes is the other unverified shape, for the reason above.

**Permanently unfixable in the suite:** `function.c` lines 261 and 265, and now also
line 96. `test.h` declares its own 24-byte `va_list` and `function.c` reads
`__va_area__` — the local this work removed, because it is the SysV mechanism and not
what this target uses. Nothing fcc emits changes that; the inconsistency is between the
suite's declaration and mingw's library. `function.c` now fails to compile on
`undefined variable "__va_area__"` rather than computing a wrong answer, which is a
better failure but is still the same recorded divergence.

## The suite result is unchanged

5 of 18, the same five, and the same eight wrong answers. Adding the builtins and the
conversion fix regressed nothing and fixed nothing in the suite — the files that fail
fail for the reasons already recorded.