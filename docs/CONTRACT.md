# The tcc contract

This is the exact surface `fcc` must satisfy to replace the bundled TinyCC.
Every item is quoted from a live source line in `vlang/v`, so it can be
re-verified rather than trusted.

Source of truth: `vlib/v/driver/driver.v` and `vlib/builtin/*.c.v`.

## Why this document exists

Without a written contract, "fcc works" is unfalsifiable. Phase 3 swaps the
backend and there is no way to tell whether a failure is a bug in the new code
generator or a feature the front end never had to support. This file is the
checklist, and `tools/contract_test.v` asserts the V-side source still contains
what is listed here.

## 1. Invocation shapes

`tcc` is invoked as an ordinary command line, from the build directory
(`cmdexec.run_in(tcc_path, tcc_args, cc_dir)`).

Three distinct shapes are used:

| Shape | Where | Purpose |
|---|---|---|
| link a cached program unit | `driver.v:14173` | one `main.c` plus cached objects, dylibs and flags |
| object output | `driver.v:14249` | `-c`, for `is_o` builds and parallel compilation |
| library runtime object | `driver.v:314` | `vlib/sync/stdatomic/atomic.c` prebuilt once |

Order matters for archives: *"static archives remain order-sensitive link
operands"* (`driver.v:9415`).

## 2. Flags the driver passes

| Flag | Source | Required behaviour |
|---|---|---|
| `-std=gnu11` | `driver.v:9396` | GNU C11, including the extensions in §4 |
| `-B<root>` | `driver.v:3151` | resource root; tcc appends `include/winapi` to its search path |
| `-I<dir>` | `driver.v:3152` | user include paths, passed through separately from `-B` |
| `-L<dir>` | `driver.v:3153` | library search |
| `-D` / `-U` / `-include` / `-isystem` … | `driver.v:1039` | preprocessor options, both joined and separated |
| `-o <file>` | `driver.v:14195` | output path |
| `-c` | `driver.v:14284` | stop after compiling to a relocatable object |
| `-shared` | `driver.v:14282` | produce a DLL instead of an executable |
| `-bt25` | `driver.v:3053` | enable tcc's runtime backtrace, depth 25 |
| `-municode` | `driver.v:3106` | `wmain` entry point |
| `-mconsole` / `-mwindows` | `driver.v:3109`, `:3113` | PE subsystem selection |
| `-Wl,--stack=33554432` | `driver.v:3119` | default stack reserve |
| `-w` | `driver.v:14178` | suppress warnings |
| `-Werror=implicit-function-declaration` | `driver.v:14178` | only this warning is fatal |
| `-l<name>` / `.lib` / `.o` / `.a` | `driver.v:1071` | libraries and objects, order preserved |
| `.dylib` / `.so` / `.tbd` | `driver.v:1071` | passed through by filename |

`-bt25` is conditional: `v3_tcc_backtrace_enabled` returns false for shared
libraries and for macOS arm64 (`driver.v:3053`).

## 3. Runtime symbols fcc must export

Not a library surface — a literal symbol requirement.

`vlib/builtin/backtraces_windows.c.v:164` and
`vlib/builtin/backtraces_nix.c.v:143` declare:

```c
fn C.tcc_backtrace(fmt &char) i32
```

and `panicing.c.v:52` and `:128` call it on every panic. The whole backtrace
feature reduces to **one function that `fcc` must provide under this exact
name**. Its semantics: print a V backtrace, then return non-zero.

`vlib/builtin/cfns.c.v:316` notes the declaration is additionally guarded by
`#ifdef __TINYC__`.

Other runtime helpers (`memcpy`, `va_arg` expansion, float conversion,
`__atomic_*`) are reached through `libtcc1.a` and
`vlib/sync/stdatomic/atomic.c.v`. The exact unresolved-symbol set is not yet
enumerated; that is the first task of phase 4.

## 4. C dialect fcc must accept

`v` does not emit plain C11. From `vlib/v/gen/c/`:

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
| `typeof(...)` (GNU) | `array.v:1049` |
| `__builtin_ctz`, `__builtin_ctzll` | `fn.v:16741` |
| `__builtin_expect` | `fn.v:16722` |
| `__atomic_fetch_add`, `__sync_*` | `fn.v:16406` |

chibicc implements most of this. The `__builtin_*` family is the part that
depends on a compiler-provided runtime library, which is why it lands in phase 4
rather than phase 2.

## 5. Error reporting

`v3_is_tcc_compilation_failure` (`driver.v:14662`) identifies the compiler by
name (`tcc`, `tinyc`, `tcc-*`, `*tinycc*`) and treats any line starting with
`tcc:` as its diagnostic format. If `fcc` reports errors differently, the
driver's fallback-to-`cc` logic will misclassify them.

`tcc_compiler_identity` (`driver.v:262`) hashes the resolved executable path, and
`tcc_atomic_object_key` (`driver.v:276`) mixes that into the object cache key,
stating: *"Only the compiler that produced the object can consume it again —
tcc emits ELF objects even on ..."*. So `fcc` must either be a genuine
replacement or never be selected implicitly; a half-compatible compiler would
poison the cache.

## 6. Resources the driver expects on disk

Under `thirdparty/tcc/`, all already present in `vlang/v` and reusable as-is:

- `include/` — MinGW headers plus `include/winapi/`
- `lib/*.def` — import library definitions (`kernel32.def`, `user32.def`,
  `msvcrt.def`, `ws2_32.def`, `gdi32.def`, `advapi32.def`, `psapi.def`,
  `shell32.def`)
- `lib/libtcc1.a` — compiler runtime helpers
- `lib/openlibm.o` — `v3_system_tcc_runtime_available` gates on this file's
  presence (`driver.v:7817`)
- `lib/runmain.o`, `lib/crt1.c`, `lib/wincrt1.c`, `lib/dllmain.c` — CRT glue
- `lib/libgc.a` — Boehm GC, prebuilt

Two consequences for `fcc`:

- Import libraries must be generated by parsing `.def` files, not by linking
  against a prebuilt `.lib`. The `.def` files are already in the repository.
- `lib/libgc.a` was compiled *by tcc*. It is COFF and should link unchanged, but
  this is a risk worth testing early — see `notes/DECISIONS.md`.

## 7. macOS caveat

`driver.v:347` records that *"macOS TCC emits ELF objects and cannot link the
Mach-O object from Clang"*, and `driver.v:1479` treats a name as tcc when it is
`tcc` or `tinyc`. macOS is therefore deferred until the COFF and ELF paths work,
as planned.