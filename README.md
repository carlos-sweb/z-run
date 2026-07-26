# Z-Run

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A **minimal script runtime** for the [z-*](https://github.com/carlos-sweb) ECMAScript engine — the first repo that makes the engine usable *outside* its own test suites. Runs a script file with real stdout, script arguments, and synchronous file I/O:

```bash
z-run script.js data.json --verbose
```

## Design: the QuickJS cut

The split copies QuickJS's engine/runtime boundary deliberately: [z-interpreter](https://github.com/carlos-sweb/z-interpreter) (the engine) knows nothing about files, processes, or event loops — its one concession to hosts is `Interpreter.defineGlobal`. Everything OS-flavored lives here, installed as an `os` global (like `console`/`Math`; these become ES modules when the engine grows `import`, roadmap item 14):

- **`os.readFile(path)`** → string. Failures are *catchable JS errors* naming the path (`try { os.readFile(p) } catch (e) { ... }`).
- **`os.writeFile(path, contents)`** — create/truncate + write.
- **`os.args`** — script arguments (everything after the script path) as an array of strings.
- **`os.exit(code)`**.

File I/O is **synchronous**, exactly like quickjs-libc's `os` module — for the scripts a runtime like this exists to run, that's the 90% case, and it needs nothing from the async machinery. The CLI: reads the script, installs `os`, runs, flushes stdout **before** reporting any error (output emitted before a crash lands in order), and exits 0 on success / 1 on usage, parse errors, or uncaught exceptions (`Uncaught TypeError: ...` on stderr, Node-style).

All file access goes through this Zig's `std.Io` interface (the `main(init: std.process.Init)` convention supplies the blocking `Threaded` implementation) — so when the event loop arrives, the same seam can host an evented backend without touching the bindings' shape.

## What deliberately isn't here (yet)

Per the project's async/runtime design (agreed 2026-07-18):

- **Event loop, `setTimeout`, promises, async fs** — Etapa C of the roadmap. The loop will live *here* (drain-jobs-then-poll, like `qjs`'s `js_std_loop`), driving the engine's public job-queue API; promise-fs arrives as blocking syscalls on a thread pool resolving promises via macrotasks.
- **`setReadHandler`-style fd callbacks** (stdin/pipes/sockets) — same phase.
- ~~Modules~~ — implemented: every script now runs as an ES module (`interp.runModule`), with this repo's loader resolving **relative** specifiers (`./x.js`, `../y.js`) against each file's directory and reading through `std.Io`. Bare specifiers (`'lodash'`) are not resolved — no node_modules algorithm. `os` stays a global (it may become an importable module later).
- ~~REPL, node-style flags (`-e`, `-p`)~~ — implemented, see Usage below. Still missing: smart multi-line continuation (an unterminated statement is just a SyntaxError on that line, not a `...` continuation prompt), Ctrl+C handling, and line editing/history (raw stdin, no readline).
- **Windows** — POSIX only, like the rest of the ecosystem.

## Usage

```bash
zig build install          # produces zig-out/bin/z-run
zig build test             # library-level tests (real files on a tmp dir)
```

```bash
z-run count-words.js notes.txt      # run a script file
z-run                                # REPL (bindings persist line to line)
z-run -e "1 + 1" -p                  # eval a code string and print the result
z-run -e "console.log('hi')"        # eval without printing (Node's -e behavior)
z-run -v                             # print the version
z-run -h                             # usage/help
z-run script.js -- --foo             # `--` ends flag parsing; --foo lands in os.args
```

The whole engine is available to scripts: classes, destructuring, getters/setters, closures, exceptions, `JSON`, `Math`, `Date`, hoisting/TDZ — everything z-interpreter's 218-test suite covers.

## Examples

**REPL** — a persistent session; bindings from one line are visible on the next (same `Interpreter`, its `script_env` is created once and reused), and a thrown exception doesn't end the session:

```
$ z-run
> 1 + 1
2
> let x = 5; x * 2
10
> throw new Error('boom')
Uncaught Error: boom
> x + 1
6
> ^D
$
```

**One-off eval** (`-e`/`--eval`, `-p`/`--print`):

```bash
z-run -e "console.log('hi')"              # hi              (like Node, -e alone doesn't auto-print)
z-run -e "1 + 1" -p                       # 2
z-run -e "[1, 2, 3].map(x => x * 2)" -p   # [2, 4, 6]
```

**A script reading a file and writing another, run with an argument:**

```js
// count-words.js
const text = os.readFile(os.args[0]);
const words = text.split(' ').filter((w) => w.length > 0);
os.writeFile('out.txt', String(words.length));
console.log(words.length, 'words');
```

```bash
$ z-run count-words.js notes.txt
3 words
```

## Standalone binaries

Bake a script into a self-contained executable (engine + script, no external `.js` needed at runtime) — `deno compile`-style, done at build time with `@embedFile`:

```bash
zig build install -Dscript=myfile.js -Dname=app -Doptimize=ReleaseSafe
./zig-out/bin/app foo bar        # runs the baked-in script; foo/bar -> os.args
```

- `-Dscript=<path>` — the script to embed (relative to the build root, or absolute). Its presence builds an extra executable alongside the normal `z-run`.
- `-Dname=<name>` — output binary name (default `app`).
- Cross-compile like any Zig build: add `-Dtarget=aarch64-linux`, etc.

The binary is fully self-contained (Zig links statically) and still *interprets* at startup — it packages the interpreter, it doesn't compile the JS to machine code. Exit codes and error reporting match the CLI (`Uncaught …` on stderr, exit 1).

**Scope:** single-file scripts, run as a script (the engine is always-strict). `import`/`export` are **not** resolved in an embedded binary — bundle the module graph first, or use the plain `z-run <file>` CLI (which does resolve relative imports). A no-toolchain bundler (`z-run compile` appending the script to the executable) is a possible future addition.

## License

MIT
