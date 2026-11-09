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

## Building AST directly (`src/ast`)

Transpiling to C text (what the Brainfuck and Bash plugins do) is the quick
path, but a plugin can also build AST nodes directly and skip the C layer:

```v
import src.ast

tok := ast.synth_tok('my-lang')          // generated code has no position
ty  := &ast.Type{kind: .basic, basic: .int_, size: 4, align: 4}
one := ast.num_node(1, ty, tok, 'my-lang')
x   := ast.var_obj('x', ty)
body := ast.block_node([ast.expr_stmt_node(
  ast.assign_node(ast.var_ref_node(x, tok, 'my-lang'), one, tok, 'my-lang'),
  tok, 'my-lang')], tok, 'my-lang')
```

What `src/ast` gives you, and where each idea comes from:

- **Categories** (`NodeKind.class/is_expr/is_stmt`): Go splits nodes into
  `Expr`/`Stmt` interfaces; here declarations are `Obj`, so two classes cover
  the set. Generic tools dispatch on category instead of listing sixty kinds.
- **Traversal** (`children`/`walk`/`walk_all`/`count_kind`,
  `collect_all`/`collect_roots`): Go's `ast.Inspect`. The front end's passes
  recurse by hand; plugins should walk. Rewrites collect first and edit after
  (`for mut` over the slice — the `resolve_goto_labels` pattern), because a
  mutating visitor interface segfaults on this toolchain, same family as the
  dropped captures. Note `walk` takes a `Visitor` interface, not a callback — this toolchain
  silently drops closure captures coerced to `fn` parameters, so a callback
  API would compile and visit nothing. `KindCounter`/`count_kind` show the
  pattern for stateful visits.
- **Provenance** (`Node.lang`, `Obj.lang`, `Type.lang`, `Token.lang`):
  Zig/Odin carry the producing language with the node. The C front end sets
  `'c'`; plugins set their own id, so mixed-language units stay diagnosable.
- **Escape hatches** (`NodeKind.plugin` + `plugin`/`plugin_data`,
  `TypeKind.plugin` + `plugin`, `Obj.plugin`/`plugin_data`): a node, type or
  symbol a plugin carries verbatim until a `post_parse` hook lowers it into
  plain kinds. Unlowered survivors are reported, never guessed at: the backend
  errors, the constant folder refuses (`is_integer` is false for opaque
  types), `--dump-ast` prints `plugin(lang:name)`, and `--to-v` emits
  `int /* plugin(lang:name) */`. This keeps the enums open without making
  every consumer list every language.

`ctx.globals` is `[][]&ast.Obj`, already language-neutral: plugin-built
`func_obj`/`var_obj` values append next to parsed C functions. Objects inherit
their type's `lang`; plugin types from `plugin_type()` are incomplete
(`size` -1) until the plugin measures them, so C's layout and conversion
logic refuses them instead of miscompiling them. Direct constructors live in
`src/ast/build.v`: `num_node`, `var_ref_node`, `binary_node`, `call_node`,
`assign_node`, `expr_stmt_node`, `block_node`, `if_node`, `return_node`,
`plugin_node`, `synth_tok`.

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
through the same pipeline, because the driver diverts any input a non-default
plugin claims into `core.run_pipeline` (see `pipeline_emit_for` in
`src/driver/driver.v`). Several inputs — in one language or several — link
into one output: after loading, `core.dedupe_generated_names` qualifies every
compiler-generated name past the first unit (`.L..1` → `.L..1.u1`, flow
labels alike), so concatenation neither collides nor silently merges. Unit 0
keeps pristine spelling, so the first unit of a multi-input build is
byte-identical to building it alone. Raw-text modes (`-E`, `--dump-tokens`)
and `--to-v` stay on the legacy path: they work on file bytes, not loaded
inputs. The pipeline always emits natively; `--extern-as` is a legacy-path
hatch. Disable it without touching code:

```toml
[plugin."example-bf-input"]
enabled = false
```

Known limitations, all shared with (not introduced by) this plugin:

- Bracket errors name the `.bf` file/line/column; errors from the generated
  C would name generated lines (none occur — the generator only emits shapes
  the endtoend corpus covers).

## CLI extensibility (no recompile)

1. In-process: `core.register_command(CliCommand{...})` — same mechanism as
   `build` / `plugin` / `config` / `init`.
2. Config-declared: `[plugin."greet"] command = "greet --hi"` makes
   `fcc greet ...` run it. Precedence is in-process, then config, then PATH.
   A disabled in-process command is skipped, so config can replace a builtin
   verb with an external one of the same name.
3. External: any `fcc-<verb>` executable on `PATH` is dispatched
   (`fcc foo --bar` runs `fcc-foo --bar`), like git/cargo subcommands.

## Multiple outputs, one invocation

One flag owned the whole run (`-S` *or* `-c`): asking for assembly *and* an
object meant compiling twice. `--emit` (repeatable) and `[output."<fmt>"]`
describe a *list* of outputs instead, each with its own path:

```console
$ fcc --emit asm=x.s --emit obj=x.o main.c   # == -S -o x.s, then -c -o x.o
$ fcc --emit asm --emit obj main.c           # main-stem defaults: main.s main.o
```

Precedence per output: `=<path>`, then `[output."<fmt>"] path`, then `-o`
(single output only), then the main-stem default (`main.c` → `main.s`).
With no `--emit` and no `[output.*]`, the legacy single-mode path runs
bit-for-bit as before; combining `-S`/`-c`/`-E`/`--dump-tokens`/`--dump-ast`/
`--to-v` with `--emit` is an error (express every output as `--emit`).
Each output runs the same per-input dispatch (legacy or pipeline), so mixed
inputs compose with every output list. Text modes (`tokens`, `preprocessed`,
`ast`, `v`) that used to ignore `-o` now honor it — into a file with `--emit
tokens=x.txt`, or to stdout exactly as before with no path.

## Installable extensions (config-declared inputs)

An external *input* plugin is a transpiler command the config names — the
same transpile-and-reuse shape as the in-process language plugins, except the
transpiler is any executable, in any language:

```toml
[plugin."wlang"]
command = "wlang-transpile"   # or: path = "C:/tools/wtrans.exe"
kind = "input"                # inferred from extensions when omitted
extensions = [".w"]
```

The command runs as `<command> <path>` and must print a C translation unit on
stdout; stderr passes through untouched. Registration is automatic on every
run (`register_external_inputs`, right after config load), and a `.w` input
diverts into the plugin pipeline exactly like `.bf`/`.sh` do — composing with
every output (`-S`, `-c`, link). Disable with `enabled = false` or
`[plugins] disabled = ["wlang"]`; compiling a file only a disabled plugin
claims fails with "needs a disabled plugin" instead of misparsing as C.

Manage declarations without editing TOML by hand:

```console
$ fcc plugin add wlang -- wlang-transpile --ext .w
$ fcc plugin list      # in-process, config-declared, and on-PATH, with [disabled]
$ fcc plugin remove wlang
```

`fcc plugin add` writes `[plugin."name"]` (command/path, kind, extensions,
formats) into `fcc.toml`, creating it when missing, and preserves the rest of
the file byte-identical; `remove` drops the section. A corrupt `fcc.toml` is
fatal for builds but not for `fcc plugin ...`, which is the tool that repairs
it. `path` (an executable file) wins over `command` (a shell line) when both
are set; on Windows, backslashes in paths are escaped on write.

## Config: fcc.toml / fcc.blip

Discovery: `--config <path>`, else `fcc.toml`, `fcc.blip`, `.fcc.toml`,
`.fcc.blip` in cwd. CLI flags always win over file values. `fcc config show`
prints the effective config. See `examples/fcc.toml` and `examples/fcc.blip`.

blip is TOML-compatible with sugar: `task "name" { ... }` desugars to
`[task."name"]`, likewise `plugin "name" { ... }` and `build { ... }`
(`src/core/blip.v`). Any valid TOML config is valid blip.

## Build files: build.v / build.blip (like build.zig)

- `build.blip` / `build.toml`: declarative tasks (`task "x" { run, depends,
  inputs, outputs }`). `fcc build [task]` runs deps first (cycle-checked).
  Tasks from `fcc.toml [task.*]` merge with `build.*` (build wins).
- A task that names `outputs` is skipped when every output exists and is
  newer than every input — build.zig's up-to-date check, so unchanged
  rebuilds print `task x (up to date)` and do nothing. Tasks without outputs
  always run. `fcc build --force` (or `-f`) bypasses the check.
- `build.v`: programmatic build importing only `os` + shelling to `fcc`
  (see `examples/build.v`). When `build.v` exists and no `build.blip` does,
  `fcc build` delegates to `v -enable-globals run build.v`.
- `fcc build --help` lists tasks with their `desc`.

Honest limits vs build.zig: freshness is mtime-based, not content-hash —
editing a file's bytes back and forth still rebuilds, and changing a task's
`run` line does not invalidate its outputs (use `--force` after editing
commands). There is no sandboxing, no parallel task execution, and no
built-in `run`/`test` step kinds: every step is a shell line. What it does
cover is the loop that matters daily: declare inputs and outputs once, and
unchanged rebuilds become no-ops.

## Run, test, watch (like `go run` / `go test` / `air`)

- `fcc run [-I dir] [-D def] [-B root] file... [-- prog args...]` compiles
  every input (any language — mixed C and Brainfuck link into one binary,
  like `fcc -c`) to a temp object, links with `gcc`, runs it, and forwards
  the exit code. Temp files are removed afterwards. Linking needs `gcc` (or
  `cc`) on PATH; headers resolve `-I` first, then `-B <root>/include`, then
  `$VCC_V_ROOT/thirdparty/tcc/include`.
- `fcc test [dir|file...] [-v]` runs the `test` task when the project defines
  one, else compiles and runs every `*_test.c` / `test_*.c` in the directory
  (each a standalone program; exit 0 passes). Reports `ok`/`FAIL` per file
  with timings and a `passed/failed` summary; exits 1 on any failure.
  Program output prints on failure, or always with `-v`.
- `fcc watch [--clear] [--debounce ms] [command...]` re-runs a command
  whenever watched files change. With no command it uses `[watch] run`,
  defaulting to `fcc build`. The `[watch]` section configures it:

```toml
[watch]
run = "fcc build"
dirs = ["."]
extensions = []     # default: every registered input extension + .blip/.toml
ignore = ["build"]  # substrings, plus .git/.o/.s/.exe by default
debounce_ms = 300
clear = false
```

```blip
task "build" {
  inputs = ["main.c"]
  outputs = ["main.s"]
  run = "fcc -S -o main.s main.c"
  depends = []
}
```

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
