---
title: Node Addon Build
---

# Node Addon Build

Use `nodeAddonBuild` when the output should be loaded by Node.js through `require()` or `import()`.

## `nodeAddonBuild`

```zig
napi_build.nodeAddonBuild(
    build: *std.Build,
    option: NodeAddonBuildOptionsWithModule,
) !*std.Build.Step.Compile
```

Example:

```zig
const addon = try napi_build.nodeAddonBuild(b, .{
    .name = "hello",
    .napi_module = napi,
    .node_api = .{
        .version = .v8,
        .experimental = false,
    },
    .root_module_options = .{
        .root_source_file = b.path("./src/hello.zig"),
        .target = target,
        .optimize = optimize,
    },
});
_ = addon;
```

## Output Name

Node addon builds use platform-specific filenames:

```text
hello.darwin-arm64.node
hello.linux-x64-gnu.node
hello.win32-x64-msvc.node
hello.wasm32-wasi.wasm      # WASI, threaded (shared memory)
hello.wasm32-wasip1.wasm    # WASI, single-threaded
```

The helper exposes these utilities:

| Helper                                   | Description                                            |
| ---------------------------------------- | ------------------------------------------------------ |
| `nodePlatformArchAbi(build, target)`     | Returns the platform-arch-abi suffix.                  |
| `nodeAddonExtension(target)`             | Returns `node` for native targets and `wasm` for WASI. |
| `nodeAddonFilename(build, name, target)` | Returns the final `.node` or `.wasm` filename.         |

## Target Selection

If `root_module_options.target` is omitted, the Node addon target defaults to the host target. Provide a target explicitly for cross builds.

## WASI Addons

The CLI accepts the napi-rs target names and maps both flavors onto Zig's single
wasm target:

```bash
# threaded: shared memory, async work runs on the emnapi worker pool
zig-napi build --target wasm32-wasip1-threads

# single-threaded: unshared memory, no workers
zig-napi build --target wasm32-wasip1
```

Zig 0.16 only knows the `wasm32-wasi` triple (`-Dtarget=wasm32-wasip1` fails with
`unknown OS: 'wasip1'`), so the CLI passes `-Dtarget=wasm32-wasi` for both and
adds `-Dcpu=baseline+atomics+bulk_memory+mutable_globals` for the threaded one.
The `atomics` CPU feature is the only flavor signal, and it is what
`nodePlatformArchAbi` maps back to `wasm32-wasi` (threaded) or `wasm32-wasip1`
(single-threaded), together with the loader file names `<binary>.wasi.cjs` and
`<binary>.wasip1.cjs`.

Artifacts, loaders, browser deployment, memory sizing and teardown are covered
in [WASM Runtime](./wasm-runtime).

### Runtime Prerequisites

WASI addons link emnapi's archive, so the project needs matching runtime
packages — `emnapi` `2.0.0-alpha.5` (a prerelease, pin the exact version),
`@emnapi/core` and `@emnapi/runtime` at that same version, and
`@napi-rs/wasm-runtime` `1.2.4` for the loaders. The build finds
`node_modules/emnapi/lib` from the addon project upwards; `-Demnapi-link-dir=<dir>`
(or `EMNAPI_LINK_DIR`) selects another archive directory, `-Demnapi-archive=<name-or-path>`
another archive. A missing archive fails the build with the searched paths and
the versions it found. [WASM Runtime](./wasm-runtime#prerequisites) lists the
archive layout and the version checks the CLI performs.

### Memory

The module imports its memory; the loader decides how much to create.

| Setting                                     | Default                                     | Meaning                                                  |
| ------------------------------------------- | ------------------------------------------- | -------------------------------------------------------- |
| `-Dwasi-initial-memory-pages=<n>`           | the linker minimum (linked data plus stack) | imported memory minimum, 64 KiB pages                    |
| `-Dwasi-max-memory-pages=<n>`               | `65536` (4 GiB)                             | imported memory maximum                                  |
| `-Dwasi-stack-size=<bytes>`                 | toolchain default (16 MiB)                  | module stack                                             |
| `.wasi_memory`                              | same defaults                               | the programmatic form of the three above                 |
| `wasm.initialMemory` / `wasm.maximumMemory` | `4000` / `65536`                            | what the generated loader passes to `WebAssembly.Memory` |

Keep the loader's initial size **below** its maximum: a Zig wasi module
allocates through `sbrk`, which grows the linear memory past its current size,
so equal limits leave no headroom and every allocation after the linked image
fails (the environment, then the worker blocks). The build rejects such option
combinations with that explanation instead of emitting a loader that traps.
[WASM Runtime](./wasm-runtime#memory-model) covers sizing, the import-matching
rules and the single-allocation limit.

### Single allocation limit

On WebAssembly a single allocation is capped at **1 GiB − 64 KiB**
(1 073 676 288 bytes) in both allocators: the C `malloc`/`calloc`/`realloc`
family the emnapi plugins call, and the Zig-side page allocator that addon code
reaches through `napi.safePageAllocator()`. Requests above the limit fail the
normal way - `null` (or `ENOMEM`) for the C functions, an out-of-memory error
for a Zig `Allocator` - instead of trapping, and a failed `realloc`/`remap`
leaves the original block valid. The cap is per allocation, not a total: the
module can still import up to 4 GiB and serve many allocations that together
exceed 1 GiB.

[WASM Runtime](./wasm-runtime#single-allocation-limit) explains which size class
sets the bound and how it interacts with the imported memory.

### What runs where

Both flavors link `libemnapi-basic-napi-rs.a`, which leaves
`napi_create_async_work` and the thread-safe function API to the host. The
`@emnapi/core` plugins (bundled by `@napi-rs/wasm-runtime`) implement them:

- single-threaded: the plugin queues work on the JavaScript thread; the loader
  passes `asyncWorkPoolSize: 0` and creates no workers.
- threaded: the plugin runs work on JavaScript worker threads. The module
  exports `emnapi_async_worker_create` / `emnapi_async_worker_init` for that
  pool; the loader passes `asyncWorkPoolSize > 0`, `onCreateWorker` and a shared
  memory.

This is **not** the same implementation napi-rs uses for its Rust WASI addons,
which link emnapi's full C composition and run async work on the uv/libuv thread
pool over real wasi pthreads. Zig 0.16 cannot build a multithreaded wasm module
(wasi pthreads are stubs there), so that archive is not linked here; do not
expect libuv- or Tokio-shaped async APIs from a zig-napi WASI addon.

The CLI also emits `<binary>.wasip1-deferred.js` and its types for the
single-threaded flavor: an ESM binding with `instantiate()`, `createInstance()`
and `dispose()` that performs no top-level I/O, so a browser can defer
instantiation and destroy instances explicitly. The Node loaders stay
synchronous for both flavors (`require` returns the binding). See
[WASM Runtime](./wasm-runtime#deferred-loader) for its contract and for the
async-work paths of both flavors.

## Windows Linking

On Windows MSVC, Node-API symbols are resolved from the current Node.js process at runtime by default. If a build needs an import library, pass `.node_import_lib`, set `NODE_LIB_FILE`, or set `NODE_LIB_DIR`.

Windows GNU builds search `LIBNODE_PATH`, then `LIBPATH`, then `PATH` for `libnode.dll`.

## Options

`NodeAddonBuildOptionsWithModule` accepts:

| Field                  | Use                                                                  |
| ---------------------- | -------------------------------------------------------------------- |
| `name`                 | Base addon name.                                                     |
| `napi_module`          | `zig-napi` module imported into the addon root.                      |
| `root_module_options`  | Source file, target, optimize mode, imports, and Zig module options. |
| `node_api`             | Node-API version and experimental mode.                              |
| `node_import_lib`      | Optional Windows import library override.                            |
| `emnapi_link_dir`      | Directory holding the emnapi archive to link for WASI targets.       |
| `emnapi_archive`       | Explicit WASI emnapi archive name or path.                           |
| `wasi_memory`          | Imported memory minimum/maximum and stack size for WASI targets.     |
| `version`              | Optional semantic version.                                           |
| `max_rss`              | Build step memory limit.                                             |
| `use_llvm` / `use_lld` | Override Zig backend/linker selection.                               |
| `zig_lib_dir`          | Optional Zig lib directory.                                          |
| `win32_manifest`       | Optional Windows manifest.                                           |

The helper injects `build_options` into the addon root and configures `@import("napi")` with the selected Node-API version.

## Install Layout

The output is installed under `zig-out/node` with the formatted filename from `nodeAddonFilename`.

On Windows, the import library is installed into the same `node` directory when Zig produces one.

## Link Behavior

The compile step sets `linker_allow_shlib_undefined = true` so Node-API symbols can be resolved by the host runtime. Windows GNU builds still link `node` explicitly after locating `libnode.dll`.
