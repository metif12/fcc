# Decision log

Decisions made while setting the project up, with the reasoning and the evidence.
Written so a later reader can tell a considered choice from an accident.

---

## D1. The code generator goes behind an interface from day one

**Decision.** `src/backend/backend.v` defines `Backend` and `Emit` before any code
generator exists.

**Why.** The expensive half of this project has no reusable implementation
(`docs/RESEARCH.md`, finding 2). If the parser were written to emit assembly
directly, the interface would be whatever those calls happened to need, and phase 3
would mean rewriting the front end. With the interface fixed up front, phase 3 is a
new implementation of a stable contract.

**Cost.** The interface has methods phase 2 will not use. Accepted: a slightly
larger surface is much cheaper than a front-end rewrite.

**Interface shape.** Follows chibicc's `codegen.c`, because that is the smallest
complete description of what a C code generator must be told. Every method is a
concrete action a backend must perform, so an unimplemented one is a compile error
rather than a silent gap.

---

## D2. Chibicc's design, not cproc's

**Decision.** Model the front end on chibicc.

**Why.** cproc looks like the better-maintained base but its README rules out the
two features V needs: no PIC — "Generation of position independent code (i.e.
shared libraries, modules, PIEs)" is listed under *What's missing* — and no
preprocessor. V passes `-shared` for DLLs.

---

## D3. lemoncmd/vcc's skeleton, chibicc's current source for the rest

**Decision.** Keep the four-file skeleton; port the missing parts from chibicc
today rather than from lemoncmd/vcc.

**Why.** lemoncmd/vcc is ~70% of a chibicc port with the easy parts finished and
the hard parts absent. Its parser predates four years of chibicc development. The
skeleton is worth keeping; it is not worth treating as authoritative.

---

## D4. Windows first, Linux second, macOS last

**Decision.** One platform at a time.

**Why.** Each needs its own object format. `driver.v:347` records that macOS TCC
emits ELF objects that cannot link against clang's Mach-O output, so a cross-format
problem already exists in the incumbent. Discovering it while three platforms are
live would be far more expensive than discovering it third.

---

## D5. The differential harness separates PASS, FAIL and BLOCKED

**Decision.** `Outcome` has three failure-ish states, and `Suite.summary()` always
prints all three.

**Why.** A missing compiler is not a test result. An earlier draft of this project
reported `PASS=N FAIL=0` from a run in which nothing was actually measured, which
is worse than no run at all. `BLOCKED` exists so that failure is visible.

**Also.** `compare()` treats two builds as equivalent only when outcome *and*
stdout match. Exit code alone would have accepted a compiler that computed the
right answer wrongly.

---

## D6. Unknown flags are a hard error; known-but-unimplemented flags are recorded

**Decision.** An unrecognised option aborts. An option vcc knows but cannot honour
yet — `-imacros`, `-idirafter`, `--sysroot` — is recorded in
`options_not_yet_honoured` and surfaced by `--verbose`.

**Why.** V computes one large flag set for every C compiler. Refusing the options
that do not apply would make vcc unusable as a drop-in, so those must be tolerated.
But silently dropping a flag vcc does not recognise produces a wrong binary with no
diagnostic, which is the worst possible failure mode. The asymmetry is deliberate.

---

## D7. `tcc_backtrace` is one function, and that is asserted

**Decision.** Treat exporting a single symbol named `tcc_backtrace` as the whole
backtrace requirement, and add a test asserting no *second* `fn C.tcc_` symbol
appears in V's sources.

**Why.** This was the most reassuring finding in the research: the deepest-looking
coupling to tcc's runtime is one function call. The test is written so that if the
surface grows, the assumption fails loudly instead of quietly costing a week.

---

## D8. The contract is a test, not a document

**Decision.** `docs/CONTRACT.md` exists, and `tests/contract/contract_test.v`
asserts every claim in it against the real V source.

**Why.** A contract written in prose rots silently as its subject changes. Each
assertion carries the section it defends, so a failure names what to go re-read:

```
CONTRACT.md §2 lists -bt25; V no longer passes it
```

**Verified.** Pointing `VCC_V_ROOT` at a doctored copy of `driver.v` with `-bt25`
renamed turns the suite red with exactly that message. A green run proves the test
can detect the violation, which is the only thing a green run is worth.

---

## D15. The front end targets full C11, chibicc-style

**Decision.** The parser, preprocessor and type system cover what chibicc covers:
the complete preprocessor, all declarators, struct/union, bitfields, enum,
typedef, function pointers, arrays, VLA, `const`/`volatile`/`restrict`.

**Why.** The whole point of the two-stage strategy is that phase 2 is validated by
chibicc's behavioural test suite, which compares runtime behaviour against gcc. A
front end scoped only to what V's codegen emits would be faster to reach, but it
would reject the very tests that make phase 2 trustworthy. Narrowing the front end
would trade the project's only strong correctness signal for a few weeks.

**Consequence.** Phase 1 is larger than the minimum. Accepted.

**Not in scope.** `-O` and `-W` selection flags are parsed and ignored, because V
only reaches for gcc/clang under `-prod` (`driver.v:7766`) and never asks vcc to
optimise.

---

## D16. Position-independent code from the start

**Decision.** The machine-code backend emits RIP-relative addressing throughout,
so `-shared` works without a second codegen path.

**Why.** On x86-64 PIC and non-PIC differ in the addressing mechanism used by
essentially every instruction, not in a corner of the backend. Retrofitting it
after phase 3 would mean reworking the emitter that phase 2 already validated.
Doing it first costs a little in phase 3 and removes a fork entirely.

**Consequence.** `vcc` becomes a genuine full replacement rather than one that
falls back to gcc for DLL builds.

---

## D17. `vcc` provides `tcc_backtrace` itself

**Decision.** Implement the backtrace in vcc's runtime, walking frames with
dbghelp on Windows.

**Why.** It keeps `vlang/v` unmodified, which matters because the alternative —
adding a second backtrace backend to V — requires upstream to accept a change and
means vcc is only usable after that lands.

**Cost, stated plainly.** Frame walking and symbolization is a subsystem in its own
right, and it must be correct: a backtrace that crashes while reporting a crash is
worse than none. It sits in phase 4, after the linker works, so a defect there
cannot block the earlier phases.

---

## Corrections to earlier claims

### C1. The `libtcc.dll` requirement was wrong

I claimed the `fastc` parallel path uses TinyCC's shared library and that `vcc`
would need a `libvcc` equivalent. That was wrong twice over.

`vlib/v/gen/fastc/link.v:19` selects the in-process library only under
`$if macos && !tinyc && !fastc_selfhost ?&& !v3_backend`. On Windows the `$else`
branch runs `fastc_run_command`, invoking the linker as a subprocess — exactly what
`vcc` will do. The whole branch is also disabled under `v3_backend`, so it is inert
in the tree this project targets.

Confirmed by absence: the only link files are `link.v` and `link_darwin.c.v`.
There is no `link_windows.c.v`, and `libtcc.dll` (359 KB) has no reference
anywhere in the tree.

**Therefore `vcc` needs nothing resembling `libtcc` on Windows.** The question is
closed. It resurfaces only in phase 6, where macOS genuinely does use it.

### C2. `libgc.a` was measured, not assumed

The bundled `thirdparty/tcc/lib/libgc.a` README history records an older archive
failing against a newer `tcc.exe` with `unresolved reference to 'tinyc_getbp'`.
Rather than assume, the archive's symbol strings were extracted:

| Symbol | Count |
|---|---|
| `tinyc_getbp` | **0** |
| any `tinyc_*` | **0** |
| `__atomic_fetch_add_8` | 1 |
| `__atomic_load_8` | 1 |
| `__atomic_or_fetch_8` | 1 |
| `__atomic_store_8` | 1 |

So `libgc.a` has no dependency on TinyCC's runtime, and the historical breakage is
gone — consistent with the tcc README's note that the `tinyc_getbp` helper was
dropped in favour of `__builtin_frame_address(0)`.

A grep for `alloca` returned 17 hits, all false positives: the substring inside
"allocated" and "allocation" in GC diagnostic strings. Worth stating because a
loose grep would have produced a confident, wrong dependency list.

**New finding.** `tcc_atomic_s_arg` (`driver.v:232`) returns an empty string on
Windows: `atomic.S` is linked only for macOS-arm64 and the BSDs. So on Windows those
four symbols come from `libtcc1.a` today, and `vcc` must supply them.

That is cheap — all four are the standard GCC libatomic ABI, and each is a single
`lock`-prefixed instruction on x86-64. Roughly forty lines, so it is not a decision
and will not be asked about again.

---

Recorded because each one cost a cycle and each fails in a misleading way.

## D18. The keyword table is a `match`, not a lookup table

**Decision.** `ast.Keyword` spellings live in `keyword_name()` and
`keyword_from_spelling()`, both `match` statements. There is no map.

**Why.** A `const map[Keyword]string` with all 50 keywords compiled into a
**43-entry map whose values were misaligned with its keys**: indexing it with
`.case_` returned `'while'`, `.do_` returned `'void'`, and seven entries were gone
entirely. Nothing errored. The symptom was `return` lexing as an identifier.

That is the worst failure mode available — a silent miscompilation in the one
function every identifier token passes through. A `match` also avoids hashing on the
lexer's hottest path, so the change is not purely defensive.

`test_keyword_name_round_trips` asserts every pair in both directions, and
`test_every_keyword_has_a_distinct_spelling` checks for duplicates. Either would
have caught the shifted table.

**Lesson.** A `const map` keyed by an enum is not reliable in this V build. The
pattern is used nowhere else in this project as a result.

## D19. `simple_escapes` is still a map, and that is a known risk

**Decision.** Leave `simple_escapes` as a `const map[string]int`.

**Why.** It has eight short single-letter keys and was verified working by direct
observation: `'\n'` decodes to 10, `'\t'` to 9, `'\x41'` to 65, `'\101'` to 65.
Converting it to a `match` would be more consistent with D18, but it is not
currently miscompiling.

**Consequence.** If an escape ever decodes to the wrong value, suspect the map first
and convert it to a `match` rather than debugging the escape decoder. Recorded so
this is not mistaken for an oversight.

---

## Bugs found by running the tokenizer on real C

Each of these produced a **clean build and a wrong result**. None would have been
found by reading the code. All are now regression tests.

### B1. `0x1F` decoded to 1

The suffix stripper removed trailing `u`/`l`/`f`/`F` without regard to base. `F` is
both a float suffix and a hexadecimal digit, so `0x1F` became `0x1`.

A first attempt added a length floor, which stopped the strip eating the base prefix
but still cut the `F`, because a floor of 3 for `0x` allows exactly one digit after
it. The fix had to make the suffix set base-aware, not merely bounded.

### B2. `0x1.8p3` was three tokens

The hexadecimal branch consumed `0x1` and stopped at the `.`, which then lexed as a
float and `p3` as an identifier. The hexadecimal path now consumes the fraction and
the `p` exponent.

### B3. `0x1.8p3` decoded to 192.0, then 72.0, instead of 12.0

`parse_hex_float` had two loops — one for the integer part, one for the fraction —
and the first did not stop scaling at the `.`, so it read `8` as the next integer
digit. Rewritten as a single pass it produced 72.0, because the second version reset
`scale` to `1.0` on seeing the `.`; the scale is already 16 for the first fractional
digit. Three wrong answers from one function, none of them raising anything.

### B4. `L"x"` lexed as the identifier `L` followed by `"x"`

The wide-prefix check ran *after* the identifier check, and `L` is an identifier
character. It now runs first, with `u` and `U` restricted to a following quote or
`8` so `unsigned` and `uint8_t` still lex as identifiers.

### B5. `L"x"` lost its prefix

`read_quoted` took a `from int` and used `from > 0` to mean "a prefix was consumed".
For `L"x"` at offset 0 the prefix position *is* 0, so the test failed: the literal
decoded correctly and only `text` came back as `"x"`. The sentinel is now
`no_prefix = -1`.

### B6. `restrict` was not a keyword

`-std=gnu11` makes `restrict` a keyword; only `__restrict__` was mapped. `restrict`,
`__restrict` and `__restrict__` now all fold onto one keyword.

### B7. A silent two-character backtick literal

`'X'` written with a backtick on one side and a single quote on the other is a
**two-character** backtick literal. It compiles and compares against the wrong value.
Three of these reached the tokenizer and were found only by hex-dumping the line
after a scripted replacement reported success while changing nothing — the pattern
did not match, and I did not count matches.

---

## Toolchain quirks hit while building this

### Q1. Module-level `pub enum` is the only accepted enum form in this V build

`pub type X = enum { ... }`, `pub type X = enum u8 { ... }` and a bare
`enum { ... }` are all rejected. The first two are the dangerous ones: they parse,
then leave `X` **undefined**, so the error appears far from the cause.

Accepted form:

```v
pub enum Name {
	field
}
```

An intermediate hypothesis — that `enum u8` collided globally because the base
type is registered by name — was wrong. It was based on a probe whose output was
truncated to the first few lines, which hid the errors I was looking for. The
lesson is recorded because it is the general failure mode: a filtered probe that
shows too little is worse than no probe.

**Consequence.** `do` and `volatile` are V reserved words and cannot be enum
fields, so they are `do_` and `volatile_`. `keyword_names` maps them back to the C
spellings, so the underscore never reaches generated code.

### Q2. Single-quoted strings interpolate `$`

`'-B${base_dir}'` interpolates. Write `'-B\${base_dir}'` for the literal.

### Q3. Character literals: both quote styles are `u8`, and only one character

In the V build this project targets, `'x'` and `` `x` `` are **both** `u8` and are
interchangeable, which differs from upstream V where the backtick form is a `rune`.
Verified directly: `b == \`\n\`` is true for `u8(10)` and `int(\`\n\`)` is 10.

A multi-character backtick literal is a compile error, not a raw string. To write a
C source fragment containing quotes or backslashes in a test, use a double-quoted V
string: `"'\\n'"` is exactly the four characters `'`, `\`, `n`, `'`, and `r"..."` works
too.

### Q4. `pub type X = enum { ... }` does not work; `pub enum X { ... }` does

Covered as D9 above. Also: a `const map` keyed by an enum is unreliable (D18).

### Q5. `Set-Content` without a separator destroys a multi-line file

Truncating a file to `Set-Content` with an array joins the elements with no
separator, collapsing the whole file onto one line. This destroyed `src/ast/token.v`
once and it was rewritten from scratch. Use the write or edit tool for source files.

### Q6. `os.is_executable` does not search `PATH`

A bare `tcc` reads as a missing compiler. Resolve with
`os.find_abs_path_of_executable` first, otherwise the harness reports a perfectly
good compiler as `BLOCKED`.

### Q7. `os.Process.run()` does not wait, and status does not self-advance

`p.run()` spawns only. `p.status` changes only when something polls or waits, so a
naive `for p.status in [.running]` loop spins until the timeout and misreports a
fast success as a timeout. Poll `p.is_alive()` instead.

### Q8. V's `set_args` quotes arguments containing spaces

`['/c', 'exit 0']` arrives at `cmd.exe` as `/c "exit 0"` and fails with exit code
1. `cmd.exe` is the pathological case, but the real driver will hit this too: any
path with a space in it must be quoted correctly.

### Q9. The recorded `v.exe` breakage did not reproduce

`AGENTS.md` in the V checkout claims `v.exe` (`e690943`) fails `os.execute` 10/10,
which would break `v test` and `v fmt`. Measured 2026-10-03: **both** `v.exe` and
`v_old.exe` (`2ffd1b8`) compile, run and pass a test file.

The note is stale or was host-specific. This project's harness records `BLOCKED`
separately for exactly this class of environment problem rather than folding it
into pass or fail.
