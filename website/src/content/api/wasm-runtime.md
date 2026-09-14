---
title: WASM Runtime
---

# WASM Runtime

A WASI target produces a `.wasm` module that JavaScript loads in place of a
native `.node` binary: `nodeAddonBuild` compiles it, `zig-napi build` drives the
compiler and writes the loaders, and the addon's exports are reached through a
generated loader instead of a `require()`d `.node` file. This page covers what
the build emits, how each host loads it, the memory contract, and the
cancellation and teardown rules that are specific to WebAssembly.

The wrapper types are the ones documented elsewhere - [Conversion Model](./conversion-model),
[Ownership](./classes-ownership), [Functions](./callback-functions) and
[Async Runtime](./async-runtime) - and the same addon source compiles for both
targets. What changes on WebAssembly is where async work runs, how much memory
an instance may use, how the instance is released, and which host restrictions
apply (worker scripts, cross-origin isolation, and hosts that refuse dynamic
Wasm compilation). The supported surface on a WASI host is what those pages and
the addon's Node-API version gates allow there; it is not a claim of full parity
with napi-rs or of every Node-API entry point.

## Flavors And Artifacts

A project names its WASI targets with the napi-rs spellings; the CLI maps both
of them onto Zig's single `wasm32-wasi` triple.

| | Threaded | Single-threaded |
| ------------------------- | ------------------------------------------------------------- | -------------------------------------------- |
| CLI target                | `wasm32-wasip1-threads` (also `wasm32-wasi`, `wasm32-wasi-preview1-threads`) | `wasm32-wasip1` |
| Zig arguments             | `-Dtarget=wasm32-wasi -Dcpu=baseline+atomics+bulk_memory+mutable_globals` | `-Dtarget=wasm32-wasi` |
| Module                    | `<binary>.wasm32-wasi.wasm`                                    | `<binary>.wasm32-wasip1.wasm`                |
| Node loader               | `<binary>.wasi.cjs`, `<binary>.wasi.d.cts`                      | `<binary>.wasip1.cjs`, `<binary>.wasip1.d.cts` |
| Browser loader            | `<binary>.wasi-browser.js`                                      | `<binary>.wasip1-browser.js`                 |
| Worker scripts            | `wasi-worker.mjs`, `wasi-worker-browser.mjs`                    | none                                          |
| Deferred loader           | none                                                            | `<binary>.wasip1-deferred.js` and its `.d.ts` |
| Linear memory             | one shared `WebAssembly.Memory`                                 | one unshared memory                           |
| Async work                | `@emnapi/core` plugin worker pool                               | `@emnapi/core` plugin on the JavaScript thread |
| Browser isolation         | cross-origin isolation required                                 | not required                                  |

The requested name does not select the flavor. The build helper derives it from
the `atomics` CPU feature of the resolved target: `wasiFlavor` reads that
feature, and `nodePlatformArchAbi` maps it back to the `wasm32-wasi` or
`wasm32-wasip1` artifact and loader stem. The CLI only injects its `-Dcpu=` line
when the build does not pass one, so a project that pins its own CPU features
keeps them, together with the flavor they imply.

A command without an explicit `--target` generates loaders for every flavor the
project configures; `--target` limits the run to one flavor, and the `zig build`
behind it compiles that flavor's module, so producing both flavors takes two
builds. Each run writes the loaders it covers and removes only the loader files
of flavors the project no longer configures, which is why building one flavor
leaves the other one's artifacts and loaders in place. The CLI also rewrites the
`files` globs and the `browser` entry in `package.json` so a published package
advertises exactly the loaders it ships. `browser.js` re-exports the optional
package of the configured flavor, preferring the single-threaded one when both
are present, because it needs no cross-origin isolation.

## Prerequisites

| Package                     | Version         | Role                                                        |
| --------------------------- | --------------- | ----------------------------------------------------------- |
| `emnapi`                    | `2.0.0-alpha.5` | the C archive the module links                               |
| `@emnapi/core`              | `2.0.0-alpha.5` | async work and thread-safe functions                          |
| `@emnapi/runtime`           | `2.0.0-alpha.5` | the emnapi context the loaders create                         |
| `@napi-rs/wasm-runtime`     | `1.2.4`         | the plugins and instantiation API the generated loaders use    |

`2.0.0-alpha.5` is a **prerelease**, pinned exactly: it introduced the archive
layout this build links (`libemnapi-basic-napi-rs.a`, plus the
`emnapi_create_env` / `emnapi_delete_env` exports that `@emnapi/core` v2 calls
while initializing the native environment). It is not the stable 2.0 release,
and the three emnapi packages have to be installed at one and the same version.

The scaffold installs the four packages as runtime dependencies:

```bash
npm install emnapi@2.0.0-alpha.5 @emnapi/core@2.0.0-alpha.5 \
  @emnapi/runtime@2.0.0-alpha.5 @napi-rs/wasm-runtime@1.2.4
```

The build finds the archive itself:

- `zig-napi build` resolves the three emnapi packages from the project and fails
  on a mixed install (`emnapi version mismatch: ...`) or on a v1 install
  (`emnapi@1.x cannot build WASI addons; zig-napi links the emnapi v2 archives`).
  It then points the build at that install through `EMNAPI_LINK_DIR`, so a
  hoisted and a nested `node_modules` cannot resolve to different releases.
- A plain `zig build` walks `node_modules/emnapi/lib` from the build root
  upwards. `-Demnapi-link-dir=<dir>` (or `EMNAPI_LINK_DIR`) selects another
  archive directory, `-Demnapi-archive=<name-or-path>` (or `EMNAPI_ARCHIVE`)
  another archive file.
- A missing archive fails the build with the paths it searched, the version it
  found, and the exact `npm install` line to fix it.

The default archive is `libemnapi-basic-napi-rs.a` from
`emnapi/lib/wasm32-wasip1/`; a threaded build also looks in
`wasm32-wasip1-threads/` and `wasm32-wasip1-threads-wasi-sdk-34/`. The full C
composition (`libemnapi-napi-rs-mt.a`) calls wasi-libc pthreads and a futex
symbol Zig 0.16 does not provide, so it is only reachable through an explicit
`emnapi_archive`.

The project builds with Zig 0.16. That toolchain accepts the `wasm32-wasi`
triple and does not know the napi-rs spelling, so `-Dtarget=wasm32-wasip1` fails
with `unknown OS: 'wasip1'`; the CLI maps both target names onto `wasm32-wasi`
for that reason. The scaffold declares Node.js 20.17 or newer.

## CLI Commands

```bash
# scaffold a project with both WASI flavors enabled
zig-napi new my-addon --no-interactive --no-enable-default-targets \
  --name my-addon --addon my_addon \
  --targets wasm32-wasip1-threads,wasm32-wasip1

# build one flavor; everything after `--` goes to `zig build`
zig-napi build --cwd my-addon --target wasm32-wasip1-threads -- --summary all

# a release build is -Doptimize=ReleaseFast
zig-napi build --cwd my-addon --target wasm32-wasip1 --release

# run the addon's own `zig build` (template projects emit index.d.ts from it)
zig-napi dts --cwd my-addon
```

`--target` also decides which loader set the run writes: with an explicit target
only that flavor is regenerated, without one every flavor the project configures
is. The loaders are written to the project root and the module is installed
under `zig-out/node`. `zig-napi build` declares only `--cwd`, `--release` and
`--target`, so its output location is not configurable; the subcommands that
wrap `@napi-rs/cli` (`artifacts`, `package`) are the ones that accept
`--build-output-dir`.

The remaining commands are not interchangeable. `zig-napi build` (and therefore
`zig-napi package`, which runs `create-npm-dirs`, a build and `artifacts`) is
what regenerates the wasm bindings and loaders; `zig-napi artifacts` regenerates
them before it calls `@napi-rs/cli`; `zig-napi dts` runs `zig build` without
selecting any particular step and leaves loader generation to the build script;
`create-npm-dirs` and `pre-publish` only call `@napi-rs/cli` and never generate
loaders.

The build validates `napi.wasm` before it spends a build on it, and a wasm-ld
failure caused by a configured memory shape prints a `zig-napi:` hint naming the
pages it passed and the stack they have to cover.

## Package Configuration

```json
{
  "napi": {
    "binaryName": "my_addon",
    "packageName": "my-addon",
    "targets": ["wasm32-wasip1-threads", "wasm32-wasip1"],
    "wasm": {
      "initialMemory": 4000,
      "maximumMemory": 65536,
      "browser": { "fs": false, "asyncInit": false, "buffer": false, "errorEvent": false }
    }
  }
}
```

| Key                             | Default              | Meaning                                                                 |
| ------------------------------- | -------------------- | ----------------------------------------------------------------------- |
| `napi.binaryName`               | required             | artifact and loader file stem                                            |
| `napi.packageName`              | `package.json` name  | base name of the optional platform packages                              |
| `napi.targets`                  | `[]`                 | which flavors get loaders                                                |
| `napi.wasm.initialMemory`       | `4000` pages         | `initial` of the `WebAssembly.Memory` the loaders allocate               |
| `napi.wasm.maximumMemory`       | `65536` pages        | `maximum` of that memory; 65536 pages is 4 GiB                           |
| `napi.wasm.browser.fs`          | `false`              | mount the `@napi-rs/wasm-runtime/fs` memfs in browser loaders            |
| `napi.wasm.browser.asyncInit`   | `false`              | use the asynchronous instantiation path in a threadless browser loader   |
| `napi.wasm.browser.buffer`      | `false`              | inject a `Buffer` implementation into the emnapi context                 |
| `napi.wasm.browser.errorEvent`  | `false`              | forward worker failures as `napi-rs-worker-error` events                 |

Both memory values are page counts and are validated before anything is
generated. `napi.wasm.initialMemory must be between 1 and 65536 pages
(4294967296 bytes)` is the range check, `must be an integer number of wasm
pages` the type check, `initialMemory (N) must not exceed napi.wasm.maximumMemory
(M)` the ordering check, and `... leaves no room to grow` the equality check.
The `browser` keys must be booleans.

Setting `initialMemory` or `maximumMemory` also passes
`-Dwasi-initial-memory-pages` / `-Dwasi-max-memory-pages` to the linker, so the
module declares the same limits the loader allocates. Leaving them unset passes
no flag and keeps the linker's own minimum, which is the default for a project
that never configured memory.

## Memory Model

The module **imports** its memory (`env.memory`) and the loader **allocates**
it. The engine matches the supplied memory against the module's declared import
type: the supplied `initial` has to be **at least** the declared minimum, and
the supplied `maximum` **at most** the declared maximum (a module that declares
a maximum also rejects a memory that declares none). A violation is a
`LinkError` at instantiation - `memory import has 0 pages, but the module
requires at least 1`, `memory import has a larger maximum than the module` - and
the generated loaders append a `[zig-napi]` line naming the pages they used.

| Knob                                        | Default                                      | Applies to                        |
| ------------------------------------------- | -------------------------------------------- | --------------------------------- |
| `-Dwasi-initial-memory-pages=<n>`           | the linker minimum (linked data plus stack)   | the module's declared minimum     |
| `-Dwasi-max-memory-pages=<n>`               | `65536` (4 GiB)                              | the module's declared maximum     |
| `-Dwasi-stack-size=<bytes>`                 | toolchain default (16 MiB)                    | the stack the linker has to fit   |
| `.wasi_memory` on `nodeAddonBuild`          | the three above                              | programmatic form of the same     |
| `napi.wasm.initialMemory` / `maximumMemory` | `4000` / `65536` pages                       | the memory the loaders allocate   |

The loader's `initial` (4000 pages, 250 MiB) is not the module's minimum: that
is whatever the linker derived from the image, and the loader's value has to be
at least that. A supplied `maximum` *below* the declared maximum is accepted and
only caps growth: the module's allocator then fails the allocations that would
have to grow past it. The CLI keeps both numbers in step by passing the
configured `napi.wasm` values to the linker as `-Dwasi-initial-memory-pages` /
`-Dwasi-max-memory-pages`, so a project it generated does not have to reason
about the direction of the check; a hand-written loader does.

Every generated loader uses the resolved `napi.wasm` values, the deferred loader
included. The deferred template carries its own 1024-page fallback for a loader
generated without an explicit value; the CLI always resolves and passes the
configured value, so a project sees 4000 unless it says otherwise.

### Headroom

On top of the engine's import matching, this toolchain needs the maximum to be
strictly above the initial size. A Zig wasi module allocates through `sbrk`, and
the Zig-side break allocator extends the heap by growing the linear memory past
its current size, so a memory with no headroom fails on the first allocation
after the linked image instead of failing a grow: the environment first, then
the worker blocks. Both the build helper and the CLI reject `initial == maximum`
with that explanation rather than emitting a loader that traps.

A small initial memory is a real configuration, not a trick: 128 pages (8 MiB)
works when the build also lowers the stack (`-- -Dwasi-stack-size=1048576`),
because then the linked image fits. There is no page-count floor; the linker
reports an image that does not fit, and the CLI adds the configured values to
that message.

### Single allocation limit

On WebAssembly a single allocation is capped at **1 GiB − 64 KiB** (1 073 676 288
bytes) in both allocators: the C `malloc`/`calloc`/`realloc` family the emnapi
plugins call, and the Zig-side page allocator that addon code reaches through
`napi.safePageAllocator()`. The cap is a wasm32 property, not a policy: the
allocator behind both is a bump allocator whose biggest size class covers `2^14`
pages of 64 KiB, and a request that rounds past it would index outside its
table. Requests above the limit fail the normal way - `null` (or `ENOMEM`) for
the C functions, an out-of-memory error for a Zig `Allocator` - instead of
trapping, and a failed `realloc`/`remap` leaves the original block valid.

The cap applies to one request, not to the instance: the requested length plus
the allocator's own rounding has to stay inside it (the C entry points add a
16-byte header and alignment padding, the Zig-side allocator its own pointer and
alignment overhead), while many allocations can together exceed 1 GiB up to the
memory maximum. Multi-gigabyte single buffers need several allocations.

Linear memory also only ever grows. The break allocator grows it when an
allocation passes the current size and reuses freed blocks from its own free
lists, so `memory.buffer.byteLength` reports the instance's high-water mark
rather than its live heap, and freeing a block does not return pages to the
host. Disposal destroys the emnapi context and tears the workers down; the
memory itself stays reachable from the binding object, so it becomes
collectable, not freed, and when the host actually reclaims those bytes (and
whether the process RSS drops) is up to the host's garbage collector.

On WebAssembly the Zig-side allocator is the page allocator behind one
module-global lock, because emnapi runs work on real JavaScript workers while
Zig still reports the target as single threaded. A custom `napi_allocator` is
reached from every one of those threads, so it has to serialize its own state
**and** take its pages from `napi.safePageAllocator()`; a lock of your own
around an unsynchronized page allocator is not the same lock, and neither is a
thread-safe wrapper whose own bookkeeping is not. See
[Ownership](./classes-ownership) for the allocator hooks.

## Node Loaders

The direct path is a normal `require` of the generated loader, and both Node
loaders are synchronous: `require()` returns a ready binding after creating the
emnapi context, allocating the memory and registering the module's exports. The
loader looks for the artifact, in order:

1. next to the loader: `<binary>.<abi>.debug.wasm`, then `<binary>.<abi>.wasm`,
2. `zig-out/node/<binary>.<abi>.wasm`, the build output,
3. the optional platform package `<packageName>-<abi>` (a packaged install).

Nothing found fails with `Cannot find <binary>.<abi>.wasm next to this loader, in
zig-out/node, or in the <package> package.`

Every binding publishes a disposal hook, a non-enumerable function keyed by a
symbol so it cannot collide with an export. It is asynchronous, so it belongs in
an `async` function or a `.then`:

```js
const addon = require("./my_addon.wasip1.cjs"); // or ./my_addon.wasi.cjs

async function main() {
  try {
    console.log(addon.add(2, 3)); // 5
  } finally {
    // A native `.node` binding has no such symbol; a WASI loader always does.
    const dispose = addon[Symbol.for("napi.rs.wasi.dispose")];
    if (dispose) await dispose();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

Disposal is terminal for that binding. The Node loader sits in the module cache,
so `require()`ing its file again returns the same module object, not a fresh
instance; an already imported browser loader behaves the same way. Code that
needs repeated, independent lifetimes uses the deferred loader's
`createInstance()` instead, which is built for exactly that.

### Universal loader selection

`zig-napi new` scaffolds an `index.js` that prefers the native `.node` binary and
falls back to the WASI loaders. Its switches are environment variables:

| Variable                | Value           | Effect                                                                |
| ----------------------- | --------------- | --------------------------------------------------------------------- |
| `NAPI_RS_FORCE_WASI`    | `true`          | use a WASI loader even when a native binding loaded                    |
|                         | `error`         | require a WASI loader and throw when none is found                     |
|                         | anything else   | native binding preferred; WASI is only a fallback                      |
| `NAPI_RS_WASI_FLAVOR`   | `wasm32-wasi`   | use the threaded loader only; implies strict WASI (no native fallback, no other flavor) |
|                         | `wasm32-wasip1` | use the single-threaded loader only, with the same strictness          |

Unset, the loader tries `wasm32-wasi` first and falls back to `wasm32-wasip1`.
An unrecognized `NAPI_RS_WASI_FLAVOR` throws with the supported list instead of
defaulting to something else. Within a flavor the candidates are
`zig-out/node/<binary>.<suffix>.cjs`, `<binary>.<suffix>.cjs`, then the optional
platform package.

The threaded loader sizes its async-work worker pool from
`NAPI_RS_ASYNC_WORK_POOL_SIZE`, or `UV_THREADPOOL_SIZE` when that is unset:
default `4`, at most `64`, and unset or `0` both mean the default. A value that
is not a positive integer in range emits a warning and falls back to the
default instead of spawning an unbounded pool. Pooled workers are `unref()`ed so
they never keep the process alive; pending async work still keeps the event loop
alive through emnapi's own request counter.

## Browser Loaders

The browser loaders are ES modules that export the addon's exports both
individually and as the default export:

```js
import addon from "./my_addon.wasip1-browser.js";
console.log(addon.add(2, 3));
```

Both `<binary>.<suffix>-browser.js` loaders `fetch` the artifact at their own
URL and instantiate from the response bytes, so the `.wasm` must be reachable
next to the emitted loader (`<binary>.<abi>.wasm`, then `zig-out/node/...`). A
missing artifact surfaces as `Failed to fetch WASI module <url>` with the HTTP
status. The deferred loader, below, is the one browser-usable loader that never
fetches.

Three deployment facts follow from that:

- The fetch is a top-level `await` in both flavors, so the loader module - and
  anything that statically imports it - evaluates asynchronously whether or not
  `asyncInit` is set. A plain `import addon from "./my_addon.wasip1-browser.js"`
  is enough in a browser or a bundler that supports top-level await; there is
  nothing flavor-specific to await yourself.
- The loaders import `@napi-rs/wasm-runtime` and `@emnapi/runtime` by bare
  specifier (plus `@napi-rs/wasm-runtime/fs` or `buffer` when those options are
  on), so they need a bundler or an import map rather than raw browser loading.
- A deployment has to serve the `.wasm`, and for the threaded flavor the worker
  script the loader creates (`wasi-worker-browser.mjs` in the browser,
  `wasi-worker.mjs` in Node), at the URLs the loader resolves from its own
  `import.meta.url` / `__dirname`.

| Flavor          | Requirement                                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| threaded        | `crossOriginIsolated === true`, which needs `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` on the document |
| single-threaded | none; the page is served without those headers and never touches a worker                                  |

The isolation requirement comes from the threaded loader instantiating a
`shared: true` memory, which is only constructible while `SharedArrayBuffer` is
available, and from the worker pool it starts. `crossOriginIsolated` is only
true in a secure context that also sends both headers ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated)),
and under `require-corp` the module response itself has to be same-origin, CORS
enabled, or carry `Cross-Origin-Resource-Policy` - otherwise the fetch is
blocked before instantiation. The single-threaded loader needs none of this: no
worker, no `SharedArrayBuffer`, no headers.

`napi.wasm.browser.asyncInit` does not change the module loading described
above; it switches the emnapi *instantiation* call from the synchronous entry
point to the asynchronous one, which a host that wants an awaitable
initialization path can request for a threadless build. Threaded builds always
use the asynchronous call, because the worker pool has to exist before the
module can be instantiated.

The threaded browser pool is the fixed async-work pool of `4` plus a reuse pool
sized from `navigator.hardwareConcurrency` (at least `2`, at most `64`, and `4`
when that value is missing or unusable).

The three `napi.wasm.browser` options change what the loader imports, so the
corresponding package has to be resolvable by the bundle:

- `fs: true` imports the memfs layer from `@napi-rs/wasm-runtime/fs`, builds the
  WASI instance with it (`preopens: { "/": "/" }`), and adds `fs` and `vol` to
  the loader's exports.
- `buffer: true` injects `Buffer` into the emnapi context features, imported from
  `@napi-rs/wasm-runtime/fs` when `fs` is also on and from the `buffer` package
  otherwise.
- `errorEvent: true` forwards worker failures to the page as
  `napi-rs-worker-error` events on `globalThis`.

## Deferred Loader

The single-threaded flavor also emits `<binary>.wasip1-deferred.js` with its
`.d.ts`: an ESM binding for hosts that forbid dynamic Wasm compilation. It
performs no top-level I/O, never fetches and never compiles bytes, and accepts
only a precompiled `WebAssembly.Module`. It exports named functions only - there
is no default export.

```bash
# a build leaves the module in zig-out/node; ship it next to the loader
cp zig-out/node/my_addon.wasm32-wasip1.wasm .
```

```js
import { createInstance } from "./my_addon.wasip1-deferred.js";

// Compiling is the caller's job, from bytes the caller fetched.
const response = await fetch(new URL("./my_addon.wasm32-wasip1.wasm", import.meta.url));
if (!response.ok) throw new Error(`wasm fetch failed: ${response.status}`);
const module = await WebAssembly.compile(await response.arrayBuffer());

const instance = await createInstance(module); // own emnapi context and memory
try {
  console.log(instance.exports.add(1, 2));
} finally {
  await instance.dispose();
}
```

| Export                       | Returns                              | Contract                                                                                             |
| ---------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `instantiate(input)`         | `Promise<exports>`                   | module-local singleton: concurrent and repeated calls with the same module share one instance and one memory allocation |
| `createInstance(input)`      | `Promise<{ exports, dispose }>`      | an independent instance with its own emnapi context and memory; `dispose()` releases that one        |
| `dispose()`                  | `Promise<void>`                      | disposes the singleton and retries cleanup retained by a failed initialization rollback               |

The singleton has its own entry points:

```js
import { instantiate, dispose } from "./my_addon.wasip1-deferred.js";

const exports = await instantiate(module); // shared module-local singleton
console.log(exports.add(1, 2));
await dispose(); // a later instantiate() may create a fresh instance
```

`input` is a `WebAssembly.Module` or a promise for one. Byte buffers, URLs and
`Response` objects are rejected with a `TypeError` that names the rule, because
those require the dynamic compilation this loader exists to avoid. A module from
another realm is normalized through `structuredClone` or `MessageChannel`
instead of being recompiled.

A host that compiles Wasm ahead of time - Cloudflare Workers with a CompiledWasm
module rule, for example - passes the module it already has:

```js
import { createInstance } from "./my_addon.wasip1-deferred.js";
import module from "./my_addon.wasm32-wasip1.wasm"; // CompiledWasm module rule

const instance = await createInstance(module);
// ...
```

That specifier is host-specific: a wrangler module rule provides it, and it is
not something a browser can fetch. The repository's acceptance for this loader
runs it in Chromium with a module compiled in the page (see [Verification](#verification)
and [Boundaries](#boundaries)); no deployment on a host of that kind was run.

Lifecycle rules:

- `instantiate()` with a different module while the singleton lives rejects;
  call `dispose()` first or use `createInstance()` for independent instances.
- A failed instantiation rolls the emnapi context back and stays retryable: a
  later call creates the singleton again.
- `instantiate()` and `dispose()` reject with `ERR_NAPI_WASI_LIFECYCLE_REENTRY`
  while the singleton's `Context.destroy()` call is still running; await the
  original cleanup promise instead of re-entering. Outside that window a pending
  disposal is serialized: `instantiate()` waits for it and then creates a fresh
  instance. `createInstance()` is independent of that lifecycle.
- The singleton is also reclaimed on `beforeExit` in Node, because a worker
  isolate can be evicted at any point. An independent instance is caller-owned:
  its `dispose()` is the release.

## Async Work And Workers

Both flavors link `libemnapi-basic-napi-rs.a`, which leaves
`napi_create_async_work` and the thread-safe function API to the host. The
generated loaders implement them with the `@emnapi/core` plugins bundled by
`@napi-rs/wasm-runtime` (`emnapiAsyncWorkPlugin`, `emnapiTSFNPlugin`), which is
what `napi.Async(..., .thread)`, `napi.Worker` and `napi.ThreadSafeFunction`
are built on there. What differs from a native build is where that work runs:

- **Threaded.** The module exports `emnapi_async_worker_create` and
  `emnapi_async_worker_init`, and the loader passes a pool size, an
  `onCreateWorker` factory and the shared memory. Work runs on JavaScript worker
  threads, in parallel, against the shared linear memory. Because those workers
  allocate through the module's exported `malloc`/`free`, the addon serializes
  the C allocation entry points and keeps `napi.safePageAllocator()` behind one
  module-global lock; a custom `napi_allocator` must be thread safe.
- **Single-threaded.** The loader passes `asyncWorkPoolSize: 0` and creates no
  workers. The same exports work, but the plugin executes the work on the
  JavaScript thread, so nothing is parallel and progress events are delivered
  inline instead of through the queue
  ([Async Runtime](./async-runtime)).
- **`.single` runtime.** The body runs on the calling thread in either flavor:
  no pool, no workers, no atomics, and the exported call does not return until
  the work has finished. It is the way to run native work without paying for a
  pool, not a way to get it off the caller's thread.

The module exports `napi_register_wasm_v1`, `emnapi_create_env` and
`emnapi_delete_env` in both flavors, plus the two worker entry points in the
threaded one, and a Zig build must not leave `pthread_*` or
`__wasi_thread_spawn` imports behind.

This is **not** the implementation napi-rs uses for its Rust WASI addons. That
one links emnapi's full C composition and runs async work on the uv/libuv thread
pool over real wasi pthreads; Zig 0.16 cannot build a multithreaded wasm module
(wasi pthreads are stubs), so the threaded flavor gets its parallelism from
JavaScript workers and there is no libuv- or Tokio-shaped async API to expect.

## Cancellation And Disposal

Cancellation is cooperative and identical in shape on every runtime: an
`AbortSignal` bound to the operation flips a cancel token, and the producer
observes it at its next checkpoint (`ctx.checkCancelled()`, `ctx.emit()`, or the
result path). See [Async Runtime](./async-runtime) for the checkpoint and
settlement-priority rules.

The WebAssembly-specific part is where those checkpoints can run:

- On the single-threaded flavor the task body executes on the host's own thread,
  so a JavaScript timer cannot preempt it. The abort is observed at the next
  checkpoint inside the body, which is why an abort raised from inside an event
  listener is enough there: the listener runs on the producer's thread, and the
  check that follows it sees the cancellation.
- On the threaded flavor the producer is a worker, so the same checkpoint is
  reached within the next few events rather than at an exact instruction. The
  loader also asks `napi_cancel_async_work` for the queued work item.
- A task that already finished keeps its result: a late cancellation does not
  rewrite a settled promise.

Teardown is a handshake the module exports and the loader drives:

| Export                            | Contract                                                                                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `napi_prepare_wasm_env_cleanup()` | idempotent; cancels the in-flight tasks it can and queues their settlements for delivery, and refuses work submitted afterwards with `Cancelled` (no event is produced) |
| `napi_wasm_env_cleanup_pending()` | count of settlements queued but not yet delivered to JavaScript                                                             |

Disposal runs that barrier, then waits in real event-loop turns for the pending
count to reach zero, and only then destroys the emnapi context and terminates
the workers. The wait is bounded (128 macrotask turns); a queue that is still
non-empty at the bound rejects with `ERR_NAPI_WASI_CLEANUP_PENDING` and the
context is left intact, so the call can be retried after the queued work has
been delivered.

Two consequences matter when an addon is embedded:

- **Await the disposal.** A settled promise is not proof that the native side is
  done: a worker can finish a task before the host publishes its completion
  callback, and destroying the context over a non-empty settlement queue is
  exactly what strands the promises the barrier exists to settle. `await
  addon[Symbol.for("napi.rs.wasi.dispose")]()` in Node and the browser, `await
  dispose()` in the deferred loader.
- **Disposal is idempotent, and terminal for a generated binding.** Repeated
  calls return the same promise. For the Node and browser loaders the module
  cache hands the same object back on a later `require()`/`import`, so nothing
  restarts; a fresh instance comes from the deferred loader's `instantiate()`
  after `dispose()`, or from `createInstance()` per instance.

## Troubleshooting

| Symptom                                                                       | Cause                                                                                   | Fix                                                                                          |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `Cannot find <binary>.<abi>.wasm next to this loader, in zig-out/node, or in ...` | the module was never built for this flavor, or it was not shipped with the loader        | build that target and copy the `.wasm` next to the loader                                     |
| `Failed to fetch WASI module <url>: 404`                                       | a browser bundle emitted the loader without the artifact                                 | copy or serve `<binary>.<abi>.wasm` at the loader's URL                                       |
| `LinkError: memory import has N pages, but the module requires at least M`     | the loader's `initial` is below the module's declared minimum                            | raise `napi.wasm.initialMemory` (or the loader's `initial`) until it covers the linked image   |
| `LinkError: memory import has a larger maximum than the module`                 | the loader's `maximum` is above the module's declared maximum                            | lower `napi.wasm.maximumMemory`, or raise `-Dwasi-max-memory-pages` to match it                |
| `RangeError: WebAssembly.Memory(): could not allocate memory`                   | the host could not reserve the requested pages; this is a platform allocation failure    | lower `initialMemory`, or accept that the environment is out of address space                  |
| allocations fail (null, `ENOMEM`, out-of-memory) while the guest still has room | the loader's `maximum` is below the declared maximum, so growth stops at the loader's cap | raise `napi.wasm.maximumMemory` together with `-Dwasi-max-memory-pages`                        |
| wasm-ld reports the initial memory as too small                                | `napi.wasm.initialMemory` is below the linked image (data plus a 16 MiB stack)            | raise `initialMemory` or lower the stack with `-- -Dwasi-stack-size=<bytes>`                  |
| build panic `... leaves no room to grow` / `must not exceed the maximum`        | `-Dwasi-initial-memory-pages` equals or exceeds `-Dwasi-max-memory-pages`                 | give the memory headroom above the linked image                                               |
| build panic `... does not fit in the imported memory minimum`                   | the stack alone is larger than the configured initial memory                              | raise the initial pages or lower `-Dwasi-stack-size`                                          |
| build panic `... no headroom for the environment or the async work pool`        | `-Dwasi-initial-memory-pages=65536` leaves the maximum nowhere to grow                    | lower the initial pages                                                                       |
| `emnapi version mismatch: emnapi@..., @emnapi/core@...`                        | the emnapi packages are not one release                                                  | install one version across `emnapi`, `@emnapi/core` and `@emnapi/runtime`                     |
| `emnapi archive for <flavor> was not found: expected ...`                       | no `node_modules/emnapi/lib` with a v2 archive was found from the build root upwards      | install emnapi 2.0.0-alpha.5, or point `-Demnapi-link-dir` at the archive directory            |
| an async task rejects with code `Cancelled` during teardown                     | the task was submitted after `napi_prepare_wasm_env_cleanup()`                            | finish submissions before disposal; this rejection is the documented shutdown behavior        |
| `... N queued settlement(s) after 128 event-loop turns` (`ERR_NAPI_WASI_CLEANUP_PENDING`) | `dispose()` ran while work was still producing events                             | await the pending promises, then call `dispose()` again                                       |
| `ERR_NAPI_WASI_LIFECYCLE_REENTRY`                                              | the deferred loader's `instantiate()` or `dispose()` ran while a `Context.destroy()` was still active | await the original cleanup promise                                                  |
| a worker stops with exit code 1 while the process is idle                       | a real worker failure, not a normal pool close                                            | check the failing task; a successful pool shutdown is not reported as an error                 |
| the process never exits                                                        | work that is still referenced keeps the event loop alive                                   | pooled workers are `unref()`ed, but pending async work, or an event listener that keeps queueing events, still holds the loop open |

## Verification

The commands below are the ones this repository uses against the WASI artifacts;
they are evidence paths, not requirements for an addon project. Each needs both
flavors built first.

```bash
# build both flavors of this repository's test addons
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1-threads -- --summary all
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1 -- --summary all

# ABI acceptance, plus the build-side memory-option validation (both flavors)
node --test --test-timeout=300000 node-test/wasm/abi.test.cjs

# concurrent producers over one shared heap, plus the C allocator edges
node --test --test-timeout=300000 node-test/wasm/concurrency.test.cjs

# generated-loader unit tests and a real npm pack, scaffold, build and load
node --test packages/zig-napi/test/*.test.cjs

# real Chromium: both flavors, the deferred loader, cross-origin isolation
PLAYWRIGHT_MODULE="$PWD/website/node_modules/playwright-core/index.mjs" \
  node node-test/wasm/browser.mjs
```

Notes on running them:

- `ZIG_NAPI_WASM_ARTIFACT_ROOT` points the ABI and concurrency suites at another
  artifact directory. It is an environment variable because `node --test` does
  not forward extra flags to the test file, so the flag spelling silently falls
  back to the default root.
- The out-of-memory case inside `abi.test.cjs` is skipped unless
  `ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT` points at a small-maximum build
  (`zig build -Dtarget=wasm32-wasi -Dcpu=baseline+atomics+bulk_memory+mutable_globals -Dwasi-max-memory-pages=520`),
  so a default run does not exercise it.
- `node-test/wasm/browser.mjs` resolves `playwright-core` from its own package,
  and this workspace installs it in `website/`; `PLAYWRIGHT_MODULE` is how you
  point it at that entry (a checkout that installs it next to the test does not
  need the variable). `CHROME_EXECUTABLE` optionally selects a Chrome binary
  instead of the `chrome` channel. The run serves the threaded flavor with
  `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp` and the single-threaded flavor
  without them, so the isolation requirement is part of the acceptance rather
  than an assumption.
- The repository's own test suite selects a flavor with a different pair of
  variables - `NAPI_RS_FORCE_WASI=error` and
  `ZIG_NAPI_WASI_FLAVOR=wasi|wasip1` - which belong to its test loader
  (`node-test/load-addon.js`), not to a scaffolded package. A generated
  package's `index.js` uses
  `NAPI_RS_WASI_FLAVOR=wasm32-wasi|wasm32-wasip1` instead, as described under
  [Node Loaders](#node-loaders).

## Boundaries

The acceptance recorded for this release, and the parts it does not reach:

- Recorded: both flavors built and loaded in Node 22 on macOS arm64; both
  flavors plus the deferred loader in real Chrome, with and without
  cross-origin isolation; the allocator and single-allocation bounds in Debug,
  ReleaseSafe and ReleaseFast; a real `npm pack` to scaffold to build to load
  run; and one out-of-memory build whose worker creation reports failure instead
  of trapping. These are recorded results from that environment, not a claim
  that every run reproduces here.
- Not recorded: a deployment to a workerd-style host. The deferred loader exists
  for hosts that forbid dynamic compilation and its module handling and
  lifecycle are exercised in Chromium, but no such deployment was run.
- Not recorded: browsers other than Chrome, and Node.js 16 or 24 for the WASI
  loaders. This repository does run its native suite on Node 16 and 24; that is
  not evidence that the wasm loaders work there.
- Not claimed: parity with napi-rs, Rust, Tokio or every Node-API entry point.
  The host-observable behavior and lifecycle contracts listed on this page are
  what this build implements, on the pinned prerelease emnapi described above.
