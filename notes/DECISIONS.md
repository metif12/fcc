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

**Why.** A `pub const map[Keyword]string` in `vcc` behaved wrongly: it reported
`len == 43` for a 50-entry literal, and `.case_` returned `'while'`. The symptom
in the compiler was that `return` lexed as an identifier.

### What actually caused it — corrected 2026-10-03

My first explanation was that this V build miscompiles enum-keyed `const` maps.
**That was wrong, and I checked it rather than leaving it in the notes.**

Isolated probes, each of which asserts its own verdict:

| Probe | Result |
|---|---|
| 50-entry enum-keyed `const` map, enum and map in one module | `len == 50`, no misalignment |
| the same, with the enum in a separate module | `len == 50`, no misalignment |
| 10-entry map where 4 keys are **not** members of the key enum | `len == 6` — **the 4 unknown keys are dropped silently, with no error** |

So the map type itself is fine. The defect is narrower and is this: **a map
literal whose key is not a member of the key's enum is silently discarded.** In
`vcc` the enum declared `_alignas`, `_alignof`, `_atomic`, `_generic`,
`_noreturn`, `_static_assert`, `_thread_local` while `keyword_names` used
`.alignas`, `.alignof`, `.atomic`, `.generic`, `.noreturn`, `.static_assert`,
`.thread_local`. Seven keys, none of them members of the enum. 50 − 7 = **43**,
exactly the length observed. I had introduced the mismatch myself in an earlier
edit and read the resulting count as a compiler bug.

The value misalignment I recorded (`case → while`) I could **not** reproduce in
isolation, so it is recorded here as observed-once, unexplained, and not
reproduced.

### Why the `match` stays anyway

Two reasons, neither of which is the original one:

1. A `const map` whose keys can be silently dropped is a trap. A `match` arm that
   names a non-existent enum member is a **compile error**, which is the failure
   mode this table needs.
2. A `match` avoids hashing on the lexer's hottest path.

`test_keyword_name_round_trips` asserts 16 pairs in both directions, and
`test_every_keyword_has_a_distinct_spelling` resolves all 50 spellings. Either
would catch a dropped or shifted key.

## D19. `simple_escapes` is still a map, and that is a known risk

**Decision.** Leave `simple_escapes` as a `const map[string]int`.

**Why.** Its keys are ordinary strings, not enum members, so the D18 hazard does
not apply — a missing key yields `none` rather than a dropped entry. It was
verified by direct observation: `'\n'` decodes to 10, `'\t'` to 9, `'\x41'` to 65,
`'\101'` to 65.

**Consequence.** If an escape ever decodes to the wrong value, check the map before
debugging the decoder. Recorded so this is not mistaken for an oversight.

---

## Verification pass, 2026-10-03

Every claim above that could be wrong was re-tested rather than asserted. Two were
wrong and one explanation was wrong.

### Two claims corrected

**D18's explanation was wrong.** I had written that this V build miscompiles
enum-keyed `const` maps. Probes say otherwise:

| Probe | Result |
|---|---|
| 50-entry enum-keyed `const` map, enum and map in one module | `len == 50`, no misalignment |
| the same, enum in a separate module | `len == 50`, no misalignment |
| 10-entry map, 4 keys **not** members of the key enum | `len == 6`, silently |

So the map type is fine. The actual rule is narrow: **a map literal key that is not a
member of the key enum is discarded without any diagnostic.** In `vcc` the enum
declared `_alignas`, `_alignof`, `_atomic`, `_generic`, `_noreturn`, `_static_assert`,
`_thread_local` while `keyword_names` used `.alignas`, `.alignof`, `.atomic`,
`.generic`, `.noreturn`, `.static_assert`, `.thread_local`. Seven mismatched keys,
50 − 7 = **43**, exactly the length observed. I created the mismatch in an earlier
edit and then read the resulting count as a compiler bug.

The value misalignment I recorded (`.case_` returning `'while'`) did **not**
reproduce in isolation. It is recorded as observed-once and unexplained.

The `match` rewrite stands, on two grounds that survive the correction: a `match` arm
naming a non-existent enum member is a compile error, which is the failure mode this
table needs; and it avoids hashing on the lexer's hottest path.

**Q2's first proof was wrong.** I concluded single-quoted strings do not interpolate,
because my probe compared `x` against another `'${base_dir}'` and both sides were
substituted. Compared against a reference built by concatenation instead, single
quotes **do** interpolate, and `\$` is the literal form. The claim was right; the
first evidence for it was not. Recorded because the mistake is easy to repeat.

### Regression tests proved able to fail

B1 and B4 were reverted and the suite re-run:

| Reverted fix | Result |
|---|---|
| remove the `!hex_int` guard in `strip_numeric_suffix` | `test_hex_integer_value` and `test_hex_integer_with_suffixes` fail with `Left: 1, Right: 31` |
| move the identifier check back ahead of the wide-literal check | `test_wide_and_utf_literals` fails with `Left: ['L', '"x"']`, `Right: ['L"x"']` |

The first attempt at reverting B1 appeared to pass, which was informative: an earlier
version of the function contained `for cond { return s }` — a loop used as an `if` —
and that was doing the actual work, so removing the condition I had edited changed
nothing. The function is now a plain loop and the revert is meaningful.

### `v fmt` did not corrupt anything mysterious: this is a known, fixed bug

An earlier revision of this note blamed `v fmt` for corrupting
`src/vcc/tokenizer.v` twice and called it a formatter defect. **That was wrong, and
checking the reports showed why.**

**The bug is real.** `v fmt -w` rewrites a typed array initializer with positional
elements into code that does not compile:

| input | `v fmt -w` output |
|---|---|
| `[]int{1, 2, 3}` | `[]int{1: , 2: , 3: }` |
| `[]string{'a', 'b'}` | `[]string{a: , b: , c: }` |
| `[]u8{35}` | `[]u8{35: }` |
| `[]u8{'x'}` | `[]u8{x: }` — the quotes are dropped too |

**It is already reported and fixed upstream.** vlang/v#29110 documents the identical
output byte for byte, and its body calls it "a data-loss bug independent of bug 1".
It was fixed by PR #29217, *parser: reject positional elements in braced array
initializers*, merged to master as `d70e43c1` on 2026-10-01 and closing the issue.

The fix rejects the syntax in the parser instead of teaching the formatter about it,
which is why `init_fields` in `vlib/v/gen/v/gen.v:2386` is unchanged:

```v ignore
fn (mut g Gen) init_fields(ids []flat.NodeId) {
	for i, fid in ids {
		f := g.a.node(fid)
		if f.value.len > 0 {
			g.write('${f.value}: ')   // correct for a map or struct, wrong for an array
		}
```

`init_fields` is shared by `.array_init`, and a positional element is stored as an
ordinary expression node carrying a `value`, so the formatter spells it as a keyed
entry. Once the parser rejects the construct, the path is unreachable.

The added test asserts the guarantee this project was missing: for each rejected
expression, `v fmt -w` must exit non-zero **and leave the file byte-identical**
(`assert os.read_file(path)! == source`).

**Why this checkout still has it.** The local V tree is on branch `v-tool` at
`665874bfd3` (`0.5.2-1977-g665874bfd3`), and:

| Tree | contains `d70e43c1` |
|---|---|
| `origin/master` | yes |
| local `HEAD` (`v-tool`) | no |

So the toolchain in use predates the fix. The source-level workaround in
`read_directive` — building the accumulator with `<<` instead of a one-element
literal — is kept, because it is harmless, but it is no longer described as a
formatter bug.

**Standing rule, unchanged and now for a different reason:** run `v fmt -w`, then
build and run the tests before reading the diff as anything but formatting.

### The toolchain in use is not current, and one binary is unusable

- `v_old.exe` (`2ffd1b8`) works for `fmt`, `test` and `run`, and is what this project
  has been verified against.
- `v.exe` (`e690943`, newer) **cannot run the formatter on this host at all**. It
  reports `exec failed (SetHandleInformation): The handle is invalid` and then claims
  `1 formatting errors` on a file that `v_old.exe` confirms is already formatted. Its
  verdict is therefore worthless and must not be read as a formatting difference.

This is the failure mode the differential harness keeps `BLOCKED` separate for.

Each of these produced a **clean build and a wrong result**. None would have been
found by reading the code. All are now regression tests.

**Two of them (B1 and B4) were re-verified on 2026-10-03 by reverting the fix and
confirming the test goes red with the exact wrong value.** The rest are covered by
tests that were observed failing before the fix was written.

## Bugs found by running the tokenizer on real C

### B1. `0x1F` decoded to 1 — *re-verified*

The suffix stripper removed trailing `u`/`l`/`f`/`F` without regard to base. `F` is
both a float suffix and a hexadecimal digit, so `0x1F` became `0x1`.

A first attempt added a length floor, which stopped the strip eating the base prefix
but still cut the `F`, because a floor of 3 for `0x` allows exactly one digit after
it. The fix had to make the suffix set base-aware, not merely bounded.

**Proof the test detects it:** removing the `!hex_int` guard makes
`test_hex_integer_value` and `test_hex_integer_with_suffixes` fail with
`Left: 1, Right: 31`.

Note the final form also replaced a `for cond { return s }` that was acting as an
`if` and doing the real work — which is how the first attempt at re-verification
appeared to fail.

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

### B4. `L"x"` lexed as the identifier `L` followed by `"x"` — *re-verified*

The wide-prefix check ran *after* the identifier check, and `L` is an identifier
character. It now runs first, with `u` and `U` restricted to a following quote or
`8` so `unsigned` and `uint8_t` still lex as identifiers.

**Proof the test detects it:** moving the identifier check back to the front makes
`test_wide_and_utf_literals` fail with `Left: ['L', '"x"']`,
`Right: ['L"x"']`.

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

### Q2. Single-quoted strings interpolate `$` — *verified twice, first attempt was wrong*

`'-B${base_dir}'` substitutes, and `'\${...}'` is the literal form. Both quote styles
behave the same here.

Two proofs, because the first probe gave the wrong answer:

- Referencing an **undefined** name inside single quotes is a compile error
  (`undefined variable: base_dir`), which interpolation alone would not explain if
  the text were merely literal.
- With `base_dir := 'SUBSTITUTED'` defined, `'-B${base_dir}'` evaluates to
  `-BSUBSTITUTED`, and comparing it against a reference built by concatenation
  (`'-' + 'B' + '$' + '{base_dir}'`) is **false**, while `'-B\${base_dir}'`
  compares **true**.

**My first probe concluded the opposite.** It compared `x` against another
single-quoted `'${base_dir}'`, so both sides were substituted and compared equal,
and I read that equality as "no interpolation". The mistake was comparing two
interpolating expressions instead of one against a constructed reference.

This matters beyond trivia: `tests/contract/contract_test.v` searches V's
`driver.v` for the literal `-B\${base_dir}`, and without the `\$` escape that
search would compile here and refer to a variable that does not exist.

### Q3. Character literals: both quote styles are `u8`, and only one character

In the V build this project targets, `'x'` and `` `x` `` are **both** `u8` and are
interchangeable, which differs from upstream V where the backtick form is a `rune`.
Verified directly: `b == \`\n\`` is true for `u8(10)` and `int(\`\n\`)` is 10.

A multi-character backtick literal is a compile error, not a raw string. To write a
C source fragment containing quotes or backslashes in a test, use a double-quoted V
string: `"'\\n'"` is exactly the four characters `'`, `\`, `n`, `'`, and `r"..."` works
too.

### Q4. `pub type X = enum { ... }` does not work; `pub enum X { ... }` does

Covered as Q1 above.

### Q5. A map-literal key that is not an enum member is dropped silently

See D18. A `const map[E]string` entry whose key is not a member of `E` is discarded
with no diagnostic: a 10-entry literal with 4 unknown keys yields `len == 6`. A
`match` arm naming a non-existent member is a compile error instead, which is why
D18 keeps the `match`.

### Q6. `Set-Content` without a separator destroys a multi-line file

Truncating a file to `Set-Content` with an array joins the elements with no
separator, collapsing the whole file onto one line. This destroyed `src/ast/token.v`
once and it was rewritten from scratch. Use the write or edit tool for source files.

### Q7. `os.is_executable` does not search `PATH`

A bare `tcc` reads as a missing compiler. Resolve with
`os.find_abs_path_of_executable` first, otherwise the harness reports a perfectly
good compiler as `BLOCKED`.

### Q8. `os.Process.run()` does not wait, and status does not self-advance

`p.run()` spawns only. `p.status` changes only when something polls or waits, so a
naive `for p.status in [.running]` loop spins until the timeout and misreports a
fast success as a timeout. Poll `p.is_alive()` instead.

### Q9. V's `set_args` quotes arguments containing spaces

`['/c', 'exit 0']` arrives at `cmd.exe` as `/c "exit 0"` and fails with exit code
1. `cmd.exe` is the pathological case, but the real driver will hit this too: any
path with a space in it must be quoted correctly.

### Q10. The recorded `v.exe` breakage did not reproduce

`AGENTS.md` in the V checkout claims `v.exe` (`e690943`) fails `os.execute` 10/10,
which would break `v test` and `v fmt`. Measured 2026-10-03: **both** `v.exe` and
`v_old.exe` (`2ffd1b8`) compile, run and pass a test file.

The note is stale or was host-specific. This project's harness records `BLOCKED`
separately for exactly this class of environment problem rather than folding it
into pass or fail.
