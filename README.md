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
- **Modules** (`import`/`export`) — engine roadmap item 14; `os` is a global until then.
- **REPL**, node-style flags (`-e`, `-p`).
- **Windows** — POSIX only, like the rest of the ecosystem.

## Usage

```bash
zig build install          # produces zig-out/bin/z-run
zig build test             # library-level tests (real files on a tmp dir)
```

```js
// count-words.js
const text = os.readFile(os.args[0]);
const words = text.split(' ').filter((w) => w.length > 0);
os.writeFile('out.txt', String(words.length));
console.log(words.length, 'words');
```

The whole engine is available to scripts: classes, destructuring, getters/setters, closures, exceptions, `JSON`, `Math`, `Date`, hoisting/TDZ — everything z-interpreter's 218-test suite covers.

## License

MIT
