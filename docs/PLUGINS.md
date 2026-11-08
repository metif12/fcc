# fcc plugin architecture

Every stage of fcc is an extension. The stock compiler ships as **default
extensions**; config disables or replaces them. No stage is special.

```
CLI args / --config fcc.toml|fcc.blip
  -> core.load_effective_config (+ build.blip tasks)
  -> driver.main: dispatch_verb (CLI plugins, else legacy flags)
  -> core.run_pipeline
       pre_parse hooks  (default-target-hook, default-verbose-hook, ...)
       inputs           (default-c-input [.c/.h], default-raw-input [.s])
       ...plus example/third-party inputs (example-bf-input [.bf/.b])
       post_parse hooks
       pre_codegen hooks
       outputs          (default-asm/tokens/preprocessed/ast/obj/exe-...)
       post_codegen / pre_link / post_build hooks
```

## Kinds

| Kind | Interface (`src/core/plugin.v`) | Defaults (`src/ext/`) |
|---|---|---|
| input | `InputPlugin{name, extensions, can_handle, load}` | `default-c-input`, `default-raw-input` — plus the worked example `example-bf-input` (§ Example: Brainfuck) |
| output | `OutputPlugin{name, formats, emit}` | `default-asm/tokens/preprocessed/ast/obj/exe-output` |
| hook | `HookPlugin{name, stage, priority, run}` | `default-target-hook`, `default-verbose-hook` |
| CLI | `CliCommand{name, usage, description, handler}` (`src/core/commands.v`) | `build`, `plugin`, `config`, `init` |

Stages: `pre_parse, post_parse, pre_codegen, post_codegen, pre_link,
post_build, on_error`. Lower `priority()` runs first.

## Writing a plugin (in-process, V)

```v
import src.core

struct MyLexer {}
fn (p MyLexer) name() string { return 'my-lexer' }
fn (p MyLexer) extensions() []string { return ['.c'] }
fn (p MyLexer) can_handle(path string) bool { return true }
fn (p MyLexer) load(path string, mut ctx core.PipelineContext) ! {
  // ... append to ctx.globals, ctx.diagnostics on error
}

fn init() { core.register_input(MyLexer{}) }
```

Then `import` your module from `src/ext` (or your own binary that imports
`src/core` + `src/driver`) and it participates in `fcc plugin list` and in
every pipeline run. Disable any default without touching code:

```toml
[plugins]
disabled = ["default-asm-output"]
```

## Example: Brainfuck (`example-bf-input`)

`src/ext/bf.v` is the worked example: a whole language in ~100 lines. It
claims `.bf`/`.b` files, transpiles Brainfuck to C (`unsigned char` tape so
`+`/`-` wrap, `putchar`/`getchar` declared not included so no headers are
needed, non-command bytes ignored as comments), and feeds the generated C
through the same preprocessor/parser/backend as C input. Register with:

```v
ext.register_bf()  // done in driver.ensure_extensions; out of the box:
```

```console
$ fcc -c -o hello.o examples/hello.bf
$ gcc -o hello.exe hello.o
$ ./hello.exe
Hello World!
```

`fcc -S`, `--dump-ast` and mixed inputs (`fcc -c a.c b.bf`) all compose
through the same pipeline (subject to the multi-file `.L` limit below),
because the driver diverts any input a non-default plugin claims into
`core.run_pipeline` (see `pipeline_emit_for` in `src/driver/driver.v`).
Raw-text modes (`-E`, `--dump-tokens`) and `--to-v` stay on the legacy path:
they work on file bytes, not loaded inputs. The pipeline always emits
natively; `--extern-as` is a legacy-path hatch. Disable it without touching
code:

```toml
[plugin."example-bf-input"]
enabled = false
```

Known limitations, all shared with (not introduced by) this plugin:

- Bracket errors name the `.bf` file/line/column; errors from the generated
  C would name generated lines (none occur — the generator only emits shapes
  the endtoend corpus covers).
- Compiling several string-carrying files in one `-c` invocation fails with
  `duplicate label ".L..1"`: the backend numbers `.L` labels per translation
  unit, and concatenation collides. The legacy C path fails identically
  (GAS reports the same redefinition), so this is parity, not a regression.

## CLI extensibility (no recompile)

1. In-process: `core.register_command(CliCommand{...})` — same mechanism as
   `build` / `plugin` / `config` / `init`.
2. External: any `fcc-<verb>` executable on `PATH` is dispatched
   (`fcc foo --bar` runs `fcc-foo --bar`), like git/cargo subcommands.

## Config: fcc.toml / fcc.blip

Discovery: `--config <path>`, else `fcc.toml`, `fcc.blip`, `.fcc.toml`,
`.fcc.blip` in cwd. CLI flags always win over file values. `fcc config show`
prints the effective config. See `examples/fcc.toml` and `examples/fcc.blip`.

blip is TOML-compatible with sugar: `task "name" { ... }` desugars to
`[task."name"]`, likewise `plugin "name" { ... }` and `build { ... }`
(`src/core/blip.v`). Any valid TOML config is valid blip.

## Build files: build.v / build.blip (like build.zig)

- `build.blip` / `build.toml`: declarative tasks (`task "x" { run, depends,
  inputs }`). `fcc build [task]` runs deps first (cycle-checked).
  Tasks from `fcc.toml [task.*]` merge with `build.*` (build wins).
- `build.v`: programmatic build importing only `os` + shelling to `fcc`
  (see `examples/build.v`). When `build.v` exists and no `build.blip` does,
  `fcc build` delegates to `v -enable-globals run build.v`.

`fcc init` writes starters; `fcc init --blip` writes the blip variants.

## Verification

- `v -enable-globals test .` — 15/15 (legacy `parse_args` path untouched;
  new dispatch only triggers on verb-first args; includes the driver divert
  mapping test, bf transpile + pipeline tests, masm encoder tests, and COFF
  structural tests).
- `v -enable-globals test src/core/` — blip desugar, TOML/blip parse,
  registry round-trip, hook/pipeline run, task ordering + cycle error.
- `v -enable-globals run tools/objtest/objtest.v` — per endtoend program:
  native `.text` byte-identical to GAS, native-linked exe behaves like the
  gas-linked one (18 match, 0 differ, 0 blocked, 2 flaky with a relink
  control, not assumed).
