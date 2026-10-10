# Research: what already exists

Survey conducted before writing any code, so the project could reuse an existing
design instead of inventing one. Every number below was measured, not recalled.

## The question

Can a TCC-like C compiler be written in pure V, and can an existing project be
reused to get there quickly?

## Finding 1: `fcc` already exists, and is a dead end as a base

`lemoncmd/fcc` — "C compiler written in V", MIT, created 2019-10-02, last push
**2024-03-05**.

Total V source: **77,550 bytes** across five files.

| File | Bytes | Role |
|---|---|---|
| `src/parser.v` | 30,525 | recursive-descent parser |
| `src/type.v` | 18,662 | C type system |
| `src/gen.v` | 15,947 | x86-64 assembly text emitter |
| `src/token.v` | 6,727 | tokenizer |
| `fcc.v` | 541 | entry point |

Its own README lists as *work in progress*: **preprocessor, initialization,
float, enum, compound literals**. There is no linker. It emits assembly text to
stdout and its test suite (`test.vsh`, ~60 cases) shells out to `gcc` to
assemble and run the result.

So it is roughly 70% of chibicc's parser/type/codegen with the *easy* parts done
and the *hard* parts — preprocessor, float, ABI, linking — absent. Useful as a
skeleton; not usable as a finished front end. Its four-and-year staleness also
means chibicc has moved well past it.

`werdl/fcc` is a fork with one contributor and one star.

## Finding 2: the ecosystem has a gap where TCC lives

| Project | Language | Size | Output | Preprocessor | Linker | PIC / `-shared` | Licence |
|---|---|---|---|---|---|---|---|
| [chibicc](https://github.com/rui314/chibicc) | C | 319,298 B C | x86-64 asm **text** | own (partial) | no — needs `as` + `ld` | yes | MIT |
| [cproc](https://github.com/michaelforney/cproc) | C | — | **QBE IL** | **no — needs external `cpp`** | no | **no, explicitly not implemented** | ISC |
| [8cc](https://github.com/rui314/8cc) | C | — | asm text | own | no | — | MIT |
| [lacc](https://github.com/larmel/lacc) | C | — | asm text | own | no | — | — |
| [TinyCC](https://bellard.org/tcc/tcc-doc.html) | C | ~4.09 MB C (all arches) | **machine code + ELF/COFF directly** | complete | **its own** | yes | LGPL |
| [vas](https://github.com/v420v/vas) | V | small | x86-64 asm text assembler | — | — | — | — |

**Every small, modern, permissively licensed C compiler emits assembly text and
delegates assembling, linking and often preprocessing to external tools.** The
one project that does what TCC does — C to machine code, to a relocatable
object, to a linked executable, in a single process — is TCC itself, and it is
LGPL and roughly twenty times larger than chibicc.

That gap is the central finding. It is why `docs/PLAN.md` is phased: the front
end is cheap and reusable, and the part that actually removes the dependency is
expensive and has no reusable implementation.

`cproc` deserves a specific warning. It looks like the ideal base — small,
maintained, permissive — but its README rules out the two things V needs: no PIC
("Generation of position independent code (i.e. shared libraries, modules,
PIEs)" is listed under *What's missing*) and no preprocessor. V passes `-shared`
for DLLs.

## Finding 3: the local V tree still depends on tcc completely

Measured in `C:\Users\MR\Projects\v` (a V3/V4-era tree with `vlib/v/ssa`,
`vlib/v/mir` and `vlib/v/gen/arm64`).

`vlib/v/gen/fastc` is named misleadingly: it is a **parallel splitter of the
generated C into units**, not a native backend. `driver.v` builds tcc command
lines in three shapes and always ends by invoking `tcc.exe`. A recursive grep for
`ELFMAG|ELFCLASS|IMAGE_FILE_MACHINE` across all of `vlib` returns **nothing**, so
V has no object writer of its own.

`thirdparty/tcc/` contains **no C source at all** — only:

- `tcc.exe` (61,440 B), `libtcc.dll` (359,424 B), `i386-win32-tcc.exe` (354,304 B)
- nine `.patch` files and a `build.ps1` that fetches and rebuilds TCC out of tree
- the MinGW plus WinAPI header set
- `lib/libtcc1.a`, `lib/openlibm.o`, `lib/runmain.o`, `lib/crt1.c`,
  `lib/wincrt1.c`, `lib/dllmain.c`, `lib/libgc.a`
- eight `.def` import-library definitions (`kernel32.def`, `user32.def`,
  `msvcrt.def`, `ws2_32.def`, `gdi32.def`, `advapi32.def`, `psapi.def`,
  `shell32.def`)
- `automation/bundle-manifest.json` (125,835 B)

Its README records that the source is cut at tinycc commit `d9d02c5` from the
`mob` branch. `tcc -v` on this machine confirms it.

So replacing tcc means replacing all of that, not just a compiler: the import
library generator, the runtime helpers, the CRT glue and the header set.

## Finding 4: the tightest coupling is a single symbol

`vlib/builtin/backtraces_windows.c.v:164` and `backtraces_nix.c.v:143` declare

```c
fn C.tcc_backtrace(fmt &char) i32
```

and `panicing.c.v:52` and `:128` call it. `cfns.c.v:316` notes the declaration is
guarded by `#ifdef __TINYC__`.

The entire backtrace feature is **one function that `fcc` must export under this
exact name**. `tests/contract/contract_test.v` asserts this stays true, and
additionally asserts no *second* `fn C.tcc_` symbol appears — if one does, phase
4 grows.

## Finding 5: V does not emit plain C11

From `vlib/v/gen/c/`:

| Construct | Source |
|---|---|
| `__attribute__((constructor))` | `fn.v:747` |
| `__attribute__((destructor))` | `fn.v:754` |
| `__attribute__((naked))` | `fn.v:2184` |
| `__attribute__((noinline))` | `fn.v:2154` |
| `__attribute__((aligned(N)))` | `names_test.v:238` |
| `__attribute__((visibility("hidden")))` | `interface.v:1754` |
| `__attribute__((visibility("default")))` | `fn.v:5418` |
| `#pragma pack(push, 1)` / `pop` | `names_test.v:202` |
| `typeof(...)` | `array.v:1049` |
| `__builtin_ctz`, `__builtin_ctzll` | `fn.v:16741` |
| `__builtin_expect` | `fn.v:16722` |
| `__atomic_fetch_add`, `__sync_*` | `fn.v:16406` |

chibicc handles most of these. The `__builtin_*` family depends on a
compiler-provided runtime library, which is why it lands in phase 4 with the
rest of the runtime rather than in phase 2 with the code generator.

## Reuse estimate

| Component | Reusable from | How much |
|---|---|---|
| lexer, preprocessor, parser, types | chibicc | ~70% by design; ~40% already written in V by lemoncmd/fcc |
| x86-64 codegen | chibicc `codegen.c` (43,920 B) | direct port |
| x86-64 instruction encoding | Intel SDM | write from spec, not from TCC (LGPL) |
| object writer and linker | **nothing** | must be written; TCC is LGPL and is the only reference |
| import libraries | `thirdparty/tcc/lib/*.def` | already in the V repo, parse them |
| tests | chibicc `make test`, TCC's suite | adoptable |

## Toolchain facts verified on this host, 2026-10-03

- `Projects\v\v_old.exe` reports `V 0.5.2 2ffd1b8`; `Projects\v\v.exe` reports
  `V 0.5.2 e690943`. **Both compile, run and `v test` successfully.** The
  previously recorded claim that `v.exe` fails `os.execute` 10/10 did not
  reproduce — `v.exe` built and ran a hello-world, and `v_old.exe` passed a test
  file. Treat the older note as stale and re-measure before relying on it.
- `thirdparty\tcc\tcc.exe` is `tcc version 0.9.28rc 2026-07-14_HEAD@d9d02c56*
  (x86_64 Windows)`.
- **V's `set_args` quotes any argument containing a space.** Passing
  `['/c', 'exit 0']` to `cmd.exe` arrives as `/c "exit 0"` and fails with exit
  code 1. This matters for a real driver: any path containing a space must be
  quoted correctly, and `cmd.exe` is the pathological case.
- **This V build accepts only module-level `pub enum Name { ... }`.** The forms
  `pub type X = enum { ... }`, `pub type X = enum u8 { ... }` and a bare
  `enum { ... }` are all rejected — the first two silently leave `X` undefined,
  the last is a parse error. Recorded in `notes/DECISIONS.md` because the
  failure mode is silent for the alias forms.
- **This V build interpolates `$` inside single-quoted strings.** A literal such
  as `'-B${base_dir}'` must be written `'-B\${base_dir}'`.
- `os.is_executable` does not search `PATH`; a bare `tcc` reads as a missing
  compiler until resolved with `os.find_abs_path_of_executable`.
- `os.Process.run()` starts without waiting, and `p.status` only advances when
  something polls or waits — so a timeout loop must use `is_alive()`, not
  `p.status`.
