# zig-napi

This project can help us to build native module libraries for OpenHarmony/HarmonyNext ArkTS and Node.js with zig-lang.

## Require

For openharmony, we must use a patched zig library to build. See detail with [zig-patch](https://github.com/openharmony-zig/zig-patch).

### Node.js requirements

The build CLI and the artifacts it produces are separate: the CLI runs on the
Node.js versions its dependencies support, while an addon only needs the runtime
of the host that loads it.

| Component | Node.js |
| --- | --- |
| `zig-napi` build CLI | `^20.17.0 \|\| ^22.13.0 \|\| >=23.5.0` — the range `@napi-rs/cli` 3.9.1 and `@inquirer/prompts` require (Node 21 and 22.0–22.12 are not supported by them) |
| Native addons (`*.node`) | any Node.js exposing the N-API version the addon targets; see the supported runtime matrix in the repository README |
| WASI loaders (`*.wasi.cjs`, `*.wasip1.cjs`, `*-browser.js`) | `^20.19.0 \|\| ^22.13.0 \|\| >=23.5.0`, the range `@napi-rs/wasm-runtime` 1.2.4 requires. The threaded flavor additionally needs `SharedArrayBuffer`; the threadless `wasm32-wasip1` flavor runs without cross-origin isolation |

## Install

We recommend you use ZON(Zig Package Manager) to install it.

```zon
// build.zig.zon
.{
    .name = "appname",
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"zig-napi" = .{
            .url = "https://github.com/openharmony-zig/zig-napi/archive/refs/tags/<GIT_TAG>.tar.gz",
            .hash = "HASH_GOES_HERE",
        },
    },
}
```

(To aquire the hash, please remove the line containing .hash, the compiler will then tell you which line to put back)

```zig
// build.zig
const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});

    const napi = zig_napi.module("napi");

    // Build ArkTS/OpenHarmony artifacts.
    const result = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .napi_module = napi,
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    _ = result;
}
```

For a Node.js addon, call `nodeAddonBuild` instead. The Node target defaults to the host target unless `root_module_options.target` is provided.

```zig
const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");

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
}
```

OpenHarmony and Node addons request Node-API v8 by default. To request a newer runtime API version or experimental Node-API, configure `node_api` in `nativeAddonBuild` or `nodeAddonBuild`:

```zig
.node_api = .{
    .version = .v10,
    .experimental = false,
},
```

When `.experimental = true`, the addon requests Node-API experimental version and enables experimental declarations in `napi-sys`.

Version-gated APIs follow the same shape as NAPI-RS feature gates: for example `ThreadSafeFunction` and `Async` require v4, while `BigInt` requires v6. If an addon selects a lower version, those wrappers fail at compile time with a message pointing back to `.node_api.version`. For OpenHarmony builds, pass `.napi_module = napi` to `nativeAddonBuild` so the configured N-API version is applied to both the addon root module and the `napi` wrapper module. If type definitions compile the same source, pass the same `.node_api` to `generateTypeDefinition`.

Node addon builds use the hand-written `src/sys/node.zig` sys layer, matching napi-rs' hand-written `napi-sys` model. OpenHarmony/ArkTS builds still use the OHOS header set under `src/sys/ohos` through `native_api.h`.

On Windows MSVC, `nodeAddonBuild` follows napi-rs and does not require a `node.lib` lookup by default; the Node-API symbols are resolved from the current Node.js process at runtime. If a build needs to force an import library, pass `.node_import_lib`, set `NODE_LIB_FILE`, or set `NODE_LIB_DIR`. Windows GNU builds follow napi-rs' `LIBNODE_PATH`, `LIBPATH`, then `PATH` search for `libnode.dll` before linking `node`.

## Usage

```zig
const napi = @import("napi");

pub fn add(left: f32, right: f32) f32 {
    return left + right;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
```

## Goal

Our goal is to provide a zig version similar to the `node-addon-api` and `napi-rs`.

- [x] Out of box building system.
- [x] Macro for napi.

## Example

We provide a simple example to help you get started in `examples/basic`.

Just run the following command to build the example:

```bash
# Build all targets
zig build

# Build single target
zig build -Dtarget=aarch64-linux-ohos
```

And you can get `libhello.so` in `zig-out`.

The Node.js example is in `examples/node`:

```bash
cd examples/node
pnpm build
pnpm test
```

It installs the addon as `zig-out/node/hello.<platform-arch-abi>.node`, for example `hello.darwin-arm64.node`, `hello.linux-x64-gnu.node`, or `hello.win32-x64-msvc.node`. For WASI threads, use `zig-napi build --target wasm32-wasip1-threads`; the CLI maps that to Zig's `wasm32-wasi` target with atomics/shared-memory features, and the output follows napi-rs naming as `hello.wasm32-wasi.wasm`.

WASI addons link emnapi's `libemnapi-basic-napi-rs.a` from a `node_modules/emnapi` install (`emnapi` `2.0.0-alpha.5`, a prerelease to pin exactly, with `@emnapi/core` and `@emnapi/runtime` at the same version and `@napi-rs/wasm-runtime` `1.2.4` for the loaders), which the build looks for next to the addon project and upwards. `--target wasm32-wasip1` builds the single-threaded flavor as `hello.wasm32-wasip1.wasm` (`hello.wasip1.cjs`, unshared imported memory), and `--target wasm32-wasip1-threads` builds the shared-memory flavor as `hello.wasm32-wasi.wasm` (`hello.wasi.cjs`, worker pool); the single-threaded flavor additionally ships a deferred ESM binding (`hello.wasip1-deferred.js`) with `instantiate()`/`createInstance()`/`dispose()`. Both are passed to Zig as `-Dtarget=wasm32-wasi` — Zig only knows that spelling — with `-Dcpu=baseline+atomics+bulk_memory+mutable_globals` on the threaded one, which is also the flag that selects the flavor.

Async work and thread-safe functions come from the `@emnapi/core` plugins in both flavors; the threaded flavor runs them on the plugin's JavaScript worker threads through the `emnapi_async_worker_create` / `emnapi_async_worker_init` exports. That is deliberately **not** napi-rs' implementation, which links emnapi's full C composition and uses the uv/libuv thread pool over real wasi pthreads: Zig 0.16 cannot build a multithreaded wasm module, so a zig-napi WASI addon has no libuv/Tokio-style async API. Memory stays a loader decision — the module imports memory with the linker minimum (257 pages by default) and a 4 GiB maximum, and the loader's `wasm.initialMemory` (4000 pages by default) must stay below `wasm.maximumMemory`, because the Zig allocator grows the linear memory past its current size. A **single** allocation is capped at 1 GiB − 64 KiB (a wasm32 bump-allocator size-class limit: `malloc`/Zig `Allocator` return null/an out-of-memory error instead of trapping above it, and a failed `realloc` keeps the old block), while the total memory can still be 4 GiB across many allocations. Build-side overrides: `-Dwasi-initial-memory-pages=<pages>`, `-Dwasi-max-memory-pages=<pages>`, `-Dwasi-stack-size=<bytes>`, plus `-Demnapi-link-dir=<dir>` (or `EMNAPI_LINK_DIR`) and `-Demnapi-archive=<name-or-path>` to select a different emnapi archive.

The package also provides a `zig-napi` CLI for Node.js addons. Zig-specific commands such as `new` and `build` are implemented by this project. Packaging commands reuse the community `@napi-rs/cli` API for npm package directory creation, artifact collection, and pre-publish processing.

The CLI requires Node.js 20.17 or newer.

Create a new Node addon project:

```bash
pnpm install
pnpm --filter @ohos-rs/zig-cli cli new ../../my-addon
cd my-addon
pnpm install
pnpm build
pnpm test
```

`zig-napi new` asks for the package name, native addon binary name, and target platforms interactively by default, matching napi-rs' `new` workflow. For scripted usage, pass `--no-interactive` with explicit options:

```bash
pnpm --filter @ohos-rs/zig-cli cli new ../../my-addon --no-interactive --name my-addon --addon my_addon --targets x86_64-unknown-linux-gnu
```

Pass `--targets <triple>` repeatedly or as a comma-separated list to choose the generated package targets manually, or pass `--enable-all-targets` to enable every napi-rs target known to the CLI.

Run the bundled Node example:

```bash
pnpm install
pnpm run node-example:package
pnpm --filter zig-napi-node-example run test
```

`zig-napi create-npm-dirs` calls `@napi-rs/cli`'s `createNpmDirs` API and creates `npm/<platform-arch-abi>` packages from the `napi` field in `package.json`. `zig-napi artifacts --output-dir zig-out/node` calls the community `artifacts` API and copies Zig's `<binary>.<platform-arch-abi>.node` or `<binary>.wasm32-wasi.wasm` outputs into those packages and into the root package. When `wasm32-wasip1-threads` is configured, `zig-napi build`, `artifacts`, and `package` also generate the napi-rs compatible `.wasi.cjs` and worker files used by `@napi-rs/wasm-runtime`. `zig-napi pre-publish` calls the community `prePublish` API to update optional dependencies and handle publish preparation.

Upstream `napi build` and `napi new` are not used directly for Zig addons because they currently expect Cargo projects and napi-rs' Rust templates.

Node.js matrix tests live in `node-test`. It mirrors the NAPI-RS example split with two independent demos:

- `node-test/napi-compat-mode` covers compat-mode style APIs and runtime-gated N-API v4/v5/v6/v7/v8 scenarios.
- `node-test/napi` covers the non compat-mode example surface such as values, strict validation, async, ThreadSafeFunction, and worker-thread loading.

The Node addon CI runs those tests on Linux, macOS, and Windows for Node.js 12, 14, 16, 18, 20, 22, and 24. It also builds `wasm32-wasip1-threads` addons and runs `node-test` with `NAPI_RS_FORCE_WASI=error` to verify the napi-rs compatible wasm runtime path.

## Website

The documentation website lives in `website` and builds as a standalone Vite site.

```bash
cd website
pnpm install
pnpm dev
pnpm build
```

## Credits

This zig-napi project is heavily inspired by:

- [napi-rs](https://github.com/napi-rs/napi-rs)
- [node-addon-api](https://github.com/nodejs/node-addon-api)
- [tokota](https://github.com/kofi-q/tokota)

## LICENSE

[MIT](./LICENSE)
