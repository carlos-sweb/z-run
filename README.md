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
z-run compile script.js -o app       # bake script.js into a standalone binary -- see "Standalone binaries" below
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

## Compile-time feature flags

`os.crypto`/`os.argsParser`/`YAML`/`TOML` are host extensions (not ECMA-262), so they can be compiled out — the disabled sibling dependency (`z-crypto`/`z-uuid`/`z-yaml`/`z-toml`/`z-args`) is never fetched, built, or linked, and the corresponding global/property is simply never attached, all default `true`:

```bash
zig build install -Dyaml=false -Dtoml=false      # drop the YAML/TOML globals entirely
zig build install -Dargs=false                    # drop os.argsParser.* entirely
zig build install -Dcrypto=false                  # drop os.crypto.* entirely
zig build install -Dcrypto-uuid=false              # keep os.crypto.* but forget os.crypto.uuid.*
```

Finer sub-namespace flags exist within `crypto`, each implicitly ANDed with the `-Dcrypto` master switch: `-Dcrypto-uuid`, `-Dcrypto-random`, `-Dcrypto-hash`, `-Dcrypto-hmac`, `-Dcrypto-aead`, `-Dcrypto-password`, `-Dcrypto-base32`, `-Dcrypto-totp`, `-Dcrypto-jws`. Run `zig build --help` for the full, self-documenting list.

## Library reference: YAML, TOML, os.crypto, os.argsParser

Every function below is runnable as-is against `z-run script.js`. Byte outputs (`Uint8Array`, from `hash`/`hmac`/`aead`/`random.bytes`/`base32.decode`) don't support `Array.from`/spread yet (a known engine gap — index/`.length` work fine), so the examples read them back with a plain index loop or round-trip them through `os.crypto.base32.encode` for a printable form.

### YAML — `YAML.parse` / `YAML.stringify`

Load a file, read and mutate it as a plain object, write it back:

```js
// yaml_demo.js
const config = YAML.parse(os.readFile('config.yaml'));
console.log(config.name, config.version, config.features.join(','));

config.features.push('crypto');
config.updated = true;
os.writeFile('config.yaml', YAML.stringify(config));
```

```bash
$ z-run yaml_demo.js
z-run 0.1.0 yaml,toml
```

### TOML — `TOML.parse` / `TOML.stringify`

```js
TOML.stringify({ name: 'z-run', version: '0.1.0', author: { name: 'carlos' } });
// name = "z-run"
// version = "0.1.0"
//
// [author]
// name = "carlos"

const parsed = TOML.parse(os.readFile('config.toml'));
console.log(parsed.name, parsed.author.name); // z-run carlos
```

### `os.crypto.uuid` — `v4()` / `v7()`

```js
os.crypto.uuid.v4(); // "0146e136-7239-4405-aabb-aaba0b01ace0" -- random
os.crypto.uuid.v7(); // "019fabc1-5fed-7869-9317-7b55556d3024" -- time-ordered (RFC 9562)
```

### `os.crypto.random` — `bytes(n)` / `int(min, max)` / `string(len[, alphabet])`

```js
os.crypto.random.bytes(8);                          // Uint8Array(8), CSPRNG
os.crypto.random.int(1, 6);                          // e.g. 5 -- dice roll, inclusive range
os.crypto.random.string(12);                         // e.g. "w10vaR6EDO0T" -- default alphanumeric alphabet
os.crypto.random.string(8, 'ABCDEF0123456789');      // e.g. "790451C1" -- custom alphabet
```

### `os.crypto.hash` — `sha256` / `sha512` / `blake3`

Same signature for all three (`(data) -> Uint8Array`), shown here via `base32.encode` for a printable digest:

```js
os.crypto.base32.encode(os.crypto.hash.sha256('hello'));
// PF3UBEAULQ7SMOLJ35SZWVYGXKQ5AMCF2P2VAAWPC7NFJZ4I7QRA====
os.crypto.base32.encode(os.crypto.hash.blake3('hello'));
```

### `os.crypto.hmac` — `sha256(key, data)` / `sha512(key, data)`

```js
os.crypto.base32.encode(os.crypto.hmac.sha256('secret-key', 'message to authenticate'));
```

### `os.crypto.aead` — `encrypt(key, plaintext[, aad])` / `decrypt(key, blob[, aad])`

XChaCha20-Poly1305, 32-byte key, `decrypt` throws a catchable error on tampering/wrong key:

```js
const key = os.crypto.random.bytes(32);
const blob = os.crypto.aead.encrypt(key, 'attack at dawn');
const plaintext = os.crypto.aead.decrypt(key, blob);   // Uint8Array back to "attack at dawn"
```

### `os.crypto.password` — `hash(password)` / `verify(hash, password)`

Argon2id, self-describing PHC string (no separate salt to manage):

```js
const phc = os.crypto.password.hash('correct horse battery staple');
// $argon2id$v=19$m=19456,t=2,p=1$...
os.crypto.password.verify(phc, 'correct horse battery staple'); // true
os.crypto.password.verify(phc, 'wrong password');               // false
```

### `os.crypto.base32` — `encode(data)` / `decode(encoded)`

```js
const encoded = os.crypto.base32.encode('hello world'); // "NBSWY3DPEB3W64TMMQ======"
os.crypto.base32.decode(encoded);                        // Uint8Array back to "hello world"
```

### `os.crypto.totp` — `hotp` / `totp` / `totpNow` / `verifyTotp`

RFC 4226/6238. `digits` must be 1–9; `window` on `verifyTotp` tolerates clock drift (in steps):

```js
const secret = 'my-shared-secret';
os.crypto.totp.hotp(secret, 0, 6);                  // "864426" -- counter-based (RFC 4226)
os.crypto.totp.totp(secret, 1700000000, 30, 6);     // "664446" -- fixed unixTime, 30s step
os.crypto.totp.totpNow(secret, 30, 6);              // code for the current time
os.crypto.totp.verifyTotp(secret, code, Math.floor(Date.now() / 1000), 30, 6, /* window */ 1);
```

### `os.crypto.jws` — `sign(headerJson, payloadJson, key)` / `verify(token, key)`

Compact JWS, HS256 only. Headers/payloads are caller-serialized JSON — `jws`, not `jwt`: no claim validation, just signature integrity:

```js
const header = JSON.stringify({ alg: 'HS256', typ: 'JWT' });
const payload = JSON.stringify({ sub: 'carlos', admin: true });
const token = os.crypto.jws.sign(header, payload, 'jws-signing-key');
// eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjYXJsb3MiLCJhZG1pbiI6dHJ1ZX0....

const verified = os.crypto.jws.verify(token, 'jws-signing-key');
JSON.parse(verified.payload).sub; // "carlos"
```

### `os.argsParser.simple(argv, specs)` — POSIX/GNU-style flag tokenizer

Binds only [z-args](https://github.com/carlos-sweb/z-args)' `Simple` tier — a `getopt_long`-style tokenizer with no auto-help and no cross-flag validation, one token per element, and (unlike a strict parser) it keeps going past an unknown flag instead of aborting. `z-args`' other three tiers (`Builder`/`Declarative`/`Commands`) are **not** exposed here: `Declarative` needs a Zig type known at compile time, which a runtime JS value structurally can never provide; `Commands`/`Builder` would need new interpreter-side machinery (persistent native objects, JS-callback dispatch) this pass deliberately didn't add.

Each spec is `{ short?: string, long?: string, kind?: 'flag' | 'value' }` (`kind` defaults to `'flag'`); each returned token is `{ type, short?, long?, value? }`, where `type` is one of `'flag'`/`'option'`/`'positional'`/`'unknownOption'`/`'missingValue'`/`'unexpectedValue'` and absent fields read as `undefined`:

```js
// args_demo.js
const tokens = os.argsParser.simple(os.args, [
  { short: 'v', long: 'verbose' },
  { short: 'o', long: 'output', kind: 'value' },
]);
for (const t of tokens) {
  console.log(t.type, t.short, t.long, t.value);
}
```

```bash
$ z-run args_demo.js -- -v -o out.txt file.txt --bogus
flag v verbose undefined
option o output out.txt
positional undefined undefined file.txt
unknownOption undefined bogus undefined
```

(the `--` is z-run's own flag terminator, not the script's — see Usage above; without it, `-v` would be parsed as z-run's `--version` instead of reaching `os.args`.)

## Standalone binaries

Two ways to bake a script into a self-contained executable (engine + script, no external `.js` needed at runtime) — `deno compile`-style. Both produce a binary with the same scope and the same runtime behavior; they differ only in *how* the script gets attached.

### Build-time: `-Dscript` (needs the Zig toolchain + this source tree)

```bash
zig build install -Dscript=myfile.js -Dname=app -Doptimize=ReleaseSafe
./zig-out/bin/app foo bar        # runs the baked-in script; foo/bar -> os.args
```

- `-Dscript=<path>` — the script to embed (relative to the build root, or absolute). Its presence builds an extra executable alongside the normal `z-run`.
- `-Dname=<name>` — output binary name (default `app`).
- Cross-compile like any Zig build: add `-Dtarget=aarch64-linux`, etc.

### `z-run compile`: no toolchain needed (works from an already-built `z-run`)

```bash
z-run compile myfile.js -o app
./app foo bar                    # runs the baked-in script; foo/bar -> os.args
```

Copies the currently-running `z-run` binary and appends the script plus a small footer (magic + length) — no `zig build` involved, so it works anywhere a plain `z-run` binary already sits (a CI image, a downloaded release, etc.), not just inside this source tree.

- `-o, --output <path>` — output binary path (required).
- `-f, --force` — overwrite `<path>` if it already exists (the default is to fail rather than silently overwrite).
- No cross-compile: the produced binary is for the same target/arch as the `z-run` that ran `compile`. Use `-Dscript` (above) to cross-compile.
- A binary produced by `compile` can't itself run `compile` again — once a binary carries a baked-in script, every invocation runs that script (that's the whole point); only a plain, unpainted `z-run` can compile. Chaining "compile from a binary I already compiled" isn't supported.

### Common to both

The binary is fully self-contained (Zig links statically) and still *interprets* at startup — it packages the interpreter, it doesn't compile the JS to machine code. Exit codes and error reporting match the CLI (`Uncaught …` on stderr, exit 1).

**Scope:** single-file scripts, run as a script (the engine is always-strict). `import`/`export` are **not** resolved in a baked-in binary — bundle the module graph first, or use the plain `z-run <file>` CLI (which does resolve relative imports).

## License

MIT
