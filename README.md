# zig-napi

[![Build test](https://github.com/openharmony-zig/zig-napi/actions/workflows/ci.yml/badge.svg)](https://github.com/openharmony-zig/zig-napi/actions/workflows/ci.yml)
[![Node Addon Matrix](https://github.com/openharmony-zig/zig-napi/actions/workflows/node-addon.yml/badge.svg)](https://github.com/openharmony-zig/zig-napi/actions/workflows/node-addon.yml)
[![npm](https://img.shields.io/npm/v/@ohos-rs/zig-cli.svg)](https://www.npmjs.com/package/@ohos-rs/zig-cli)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/openharmony-zig/zig-napi/blob/main/LICENSE)

Build native addons for **Node.js**, **WASI**, and **OpenHarmony / HarmonyOS NEXT ArkTS** with [Zig](https://ziglang.org/).

zig-napi provides a Zig module library and a `zig-napi` CLI. The library gives you a Zig-native N-API surface, and the CLI scaffolds, builds, packages, and publishes addons with the same project layout and flags as [napi-rs](https://github.com/napi-rs/napi-rs). The goal is to offer the Zig equivalent of [`node-addon-api`](https://github.com/nodejs/node-addon-api) and `napi-rs`.

- One codebase for Node.js native addons, single- and multi-threaded WASI, and OpenHarmony ArkTS HARs.
- napi-rs-compatible `new`, `build`, `artifacts`, `pre-publish`, `version`, `universalize`, and `rename` workflows.
- Zig build integration through `nodeAddonBuild`, `nativeAddonBuild`, and `generateTypeDefinition`.
- Captured closures, typed Promise/iterator/stream protocols, owned collections and JSON, shared/weak references, and thread-safe functions.
- Tested on Node.js 12–24 plus a QEMU OpenHarmony HAP pipeline.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Use as a Zig dependency](#use-as-a-zig-dependency)
- [Writing an addon](#writing-an-addon)
- [CLI reference](#cli-reference)
- [WASI](#wasi)
- [Examples](#examples)
- [Testing](#testing)
- [Compatibility with napi-rs](#compatibility-with-napi-rs)
- [Documentation website](#documentation-website)
- [Credits](#credits)
- [License](#license)

## Requirements

Use [Zig 0.17.0](https://ziglang.org/download/) for Node.js addons and WASI builds. OpenHarmony builds require the patched toolchain from the [zig-patch 0.17.0 release](https://github.com/openharmony-zig/zig-patch/releases/tag/0.17.0). Put the appropriate toolchain on `PATH` and confirm that `zig version` prints `0.17.0`.

CI uses [`mlugg/setup-zig@v2`](https://github.com/mlugg/setup-zig) for Node.js/WASI and lint/format jobs, and [`openharmony-zig/setup-zig-ohos@v0.1.0`](https://github.com/openharmony-zig/setup-zig-ohos) for OpenHarmony.

### Node.js requirements

The build CLI and the artifacts it produces are independent: the CLI runs on the Node.js versions its dependencies support, while an addon only needs the runtime of the host that loads it.

| Component                                                   | Node.js                                                                                                                                                                                                                            |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `zig-napi` build CLI                                        | `^20.17.0 \|\| ^22.13.0 \|\| >=23.5.0` — the range required by `@napi-rs/cli` 3.10.12 and `@inquirer/prompts` (Node 21 and Node 22.0–22.12 are not supported by them)                                                              |
| Native addons (`*.node`)                                    | Any Node.js exposing the N-API version the addon targets; see the [Node.js test matrix](#testing)                                                                                                                                  |
| WASI loaders (`*.wasi.cjs`, `*.wasip1.cjs`, `*-browser.js`) | `^20.19.0 \|\| ^22.13.0 \|\| >=23.5.0`, the range required by `@napi-rs/wasm-runtime` 1.2.7. The threaded flavor additionally needs `SharedArrayBuffer`; the threadless `wasm32-wasip1` flavor runs without cross-origin isolation |

## Quick start

### Scaffold a Node.js or WASI addon

```bash
pnpm dlx @ohos-rs/zig-cli new my-addon

cd my-addon
pnpm install
pnpm run build
pnpm test
```

`zig-napi new` asks for the package name, native addon binary name, and target platforms interactively, matching napi-rs' `new` workflow. For scripted usage, pass `--no-interactive` with explicit options:

```bash
pnpm dlx @ohos-rs/zig-cli new my-addon --no-interactive --name my-addon --addon my_addon --targets x86_64-unknown-linux-gnu
```

Pass `--targets <triple>` repeatedly or as a comma-separated list to choose the generated package targets, or pass `--enable-all-targets` to enable every Node/WASI target known to the CLI.

`new` immediately creates a `package.json` and README in `npm/<platform-arch-abi>/` for each selected target, including separate `wasm32-wasi` and `wasm32-wasip1` packages when both WASI flavors are selected. These directories hold package metadata; build each target with `zig-napi build --platform --target <triple>` and run `zig-napi artifacts --output-dir zig-out/node` to fill them with binaries and loaders. A build compiles the host target by default, or the target specified by `--target`.

`new` defaults to pnpm, Node-API 4, the MIT license, and AVA, with TypeScript declarations and GitHub Actions enabled. Use `--package-manager yarn` to select Yarn. The other defaults can be changed with `--min-node-api 1` through `10`, `--license`, `--enable-type-def=false`, or `--enable-github-actions=false`.

The generated CI builds the selected targets with stock Zig 0.17, tests host-compatible/WASI binaries, and collects the platform packages. Pushing a tag that matches the addon version (for example, `v1.2.3`) publishes the platform tarballs first and the root tarball last. Stable releases use `latest` and prereleases use `next`. Configure npm trusted publishing for the generated `CI.yml` on the root and platform packages, or set the repository's `NPM_TOKEN` secret. `new --dry-run` prints the plan without creating files or invoking Zig.

By default, `new` pins the Zig dependency in `build.zig.zon` to the `0.2.0` GitHub archive and its verified package hash. Pass `--zig-napi <checkout>` to use local sources for development or offline generation.

### Scaffold an OpenHarmony ArkTS addon

To generate an OpenHarmony native library and a DevEco Studio HAR project, select the OHOS template.

```bash
npx zig-napi new my-library --template ohos --no-interactive
cd my-library
zig build --prefix package/libs
ohpm install
hvigorw --mode module -p module=addon@default assembleHar
```

Use the patched Zig 0.17.0 and set `OHOS_NDK_HOME` to the SDK directory containing `native/sysroot`. The Zig build emits the three native ABIs and regenerates the ArkTS declarations. The HAR exposes the Zig functions through its package name. During development, add `--zig-napi /path/to/zig-napi` to generate against a local checkout.

## Use as a Zig dependency

We recommend installing the library through Zig's package manager in `build.zig.zon`.

```zon
// build.zig.zon
.{
    .name = "appname",
    .version = "0.0.0",
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .@"zig-napi" = .{
            .url = "https://github.com/openharmony-zig/zig-napi/archive/refs/tags/<GIT_TAG>.tar.gz",
            .hash = "HASH_GOES_HERE",
        },
    },
}
```

To acquire the hash, run `zig fetch --save <url>`, or remove the `.hash` line and let the compiler report the expected value.

For an OpenHarmony/ArkTS addon, call `nativeAddonBuild`:

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

When `.experimental = true`, the addon requests the Node-API experimental version and enables experimental declarations in `napi-sys`.

Version-gated APIs follow the same shape as NAPI-RS feature gates: for example, `ThreadSafeFunction` and `Async` require v4, while `BigInt` requires v6. If an addon selects a lower version, those wrappers fail at compile time with a message pointing back to `.node_api.version`. For OpenHarmony builds, pass `.napi_module = napi` to `nativeAddonBuild` so the configured N-API version is applied to both the addon root module and the `napi` wrapper module. If type definitions compile the same source, pass the same `.node_api` to `generateTypeDefinition`.

Node addon builds use the hand-written `src/sys/node.zig` sys layer, matching napi-rs' hand-written `napi-sys` model. OpenHarmony/ArkTS builds still use the OHOS header set under `src/sys/ohos` through `native_api.h`.

On Windows MSVC, `nodeAddonBuild` follows napi-rs and does not require a `node.lib` lookup by default; the Node-API symbols are resolved from the current Node.js process at runtime. If a build needs to force an import library, pass `.node_import_lib`, set `NODE_LIB_FILE`, or set `NODE_LIB_DIR`. Windows GNU builds follow napi-rs' `LIBNODE_PATH`, `LIBPATH`, then `PATH` search for `libnode.dll` before linking `node`.

## Writing an addon

```zig
const napi = @import("napi");

pub fn add(left: f32, right: f32) f32 {
    return left + right;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
```

## CLI reference

The `zig-napi` CLI is published as [`@ohos-rs/zig-cli`](https://www.npmjs.com/package/@ohos-rs/zig-cli). Zig-specific commands such as `new` and `build` are implemented by this project. Packaging commands reuse the community `@napi-rs/cli` API for npm package directory creation, artifact collection, and pre-publish processing.

| Command                      | Purpose                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| `new [dir]`                  | Create a Zig Node.js/WASI or OpenHarmony addon project.                                     |
| `build`                      | Run `zig build` and generate bindings, declarations, and WASI loaders.                      |
| `dts`                        | Run `zig build` so template projects emit `index.d.ts`.                                     |
| `create-npm-dirs`            | Create `npm/<platform-arch-abi>` platform packages from the `napi` field in `package.json`. |
| `artifacts`                  | Collect built binaries and loaders into the platform packages and the root package.         |
| `pre-publish` / `prepublish` | Update optional dependencies and prepare packages for publishing.                           |
| `version`                    | Update versions in platform npm packages.                                                   |
| `universalize`               | Combine macOS binaries into a universal binary.                                             |
| `rename`                     | Rename the Zig addon and platform package metadata.                                         |
| `package`                    | Run `create-npm-dirs`, `build`, and `artifacts` in sequence.                                |

`zig-napi create-npm-dirs` calls `@napi-rs/cli`'s `createNpmDirs` API. `zig-napi artifacts --output-dir zig-out/node` calls the community `artifacts` API and copies Zig's `<binary>.<platform-arch-abi>.node` or `<binary>.wasm32-wasi.wasm` outputs into those packages and into the root package. When `wasm32-wasip1-threads` is configured, `build`, `artifacts`, and `package` also generate the napi-rs-compatible `.wasi.cjs` and worker files used by `@napi-rs/wasm-runtime`. `zig-napi pre-publish` calls the community `prePublish` API to update optional dependencies and handle publish preparation.

CLI compatibility is checked against the pinned `@napi-rs/cli` **3.10.12** command definitions:

| Commands                                                                                | Implementation                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `create-npm-dirs`, `artifacts`, `pre-publish` / `prepublish`, `version`, `universalize` | Public napi-rs argument parsers and APIs, including their defaults, aliases, configuration merging, and `--root-publisher`.                                                                                              |
| `new`                                                                                   | Zig scaffold with the corresponding Node-API, license, target, package manager, declarations, CI, and dry-run choices; platform metadata uses `createNpmDirs`.                                                           |
| `build`                                                                                 | Zig compilation; public `readNapiConfig`, `writeJsBinding`, and declaration-header API, with Zig declaration processing.                                                                                                 |
| `rename`                                                                                | Public napi-rs API for metadata changes; Zig adapter for binary names, source references, manifests, and generated files. `--name` changes the root package, while `--package-name` changes the platform package prefix. |

Build output defaults follow napi-rs: plain `<binary>.node` without `--platform`; `<binary>.<platform>.node` and an `index.js` platform loader with `--platform`. Generated build scripts pass `--platform`. `--output-dir/-o` selects the final binary/binding/declaration directory; `--target-dir` selects Zig's installation prefix. `--js/--js-binding`, `--no-js`, `--format esm|commonjs`, `--esm`, and `--commonjs` control bindings. For example, use `--esm --js index.mjs` for an ESM filename in a CommonJS package. Rust-style target triples and Zig triples are accepted; `--cross-compile` uses Zig's built-in cross compilation.

`--dts`, `--dts-header`, `--no-dts-header`, `--const-enum=false`, `--runtime-string-enum`, `--dts-cache=false`, `--strip`, `--release`, `--verbose`, `--watch`, and `--pipe` are implemented for Zig builds. Header configuration (`napi.dtsHeader`, `napi.dtsHeaderFile`) follows the public upstream API. `--manifest-path` takes a Zig build file (or `.zig.zon`); for `rename` it takes the `.zig.zon` manifest. Global `-v/--version` prints the CLI version; `new -v` selects Node-API and `build -v` enables verbose output.

Cargo-specific `--bin`, `--package/-p`, `--profile`, `--features/-F`, `--all-features`, `--no-default-features`, `--use-cross`, and `--use-napi-cross` are rejected before compilation. Use Zig build options after `--` instead. OHOS targets and `--ohos-sign` belong to the separate OHOS toolchain. These are explicit language/platform boundaries, not supported Cargo behaviors. Zig-only `dts` and `package` remain convenience commands; `package --dry-run` performs no build and writes nothing. Upstream `new` and `build` themselves require Rust/Cargo and are not called.

## WASI

WASI addons link emnapi's `libemnapi-basic-napi-rs.a` from a `node_modules/emnapi` install. Pin `emnapi` `2.0.0-beta.3`, with `@emnapi/core` and `@emnapi/runtime` at the same version and `@napi-rs/wasm-runtime` `1.2.7` for the loaders. The build looks for the install next to the addon project and upwards.

| Target                  | Output                     | Loader                                                                                                                             | Memory                                    |
| ----------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `wasm32-wasip1`         | `hello.wasm32-wasip1.wasm` | `hello.wasip1.cjs`, plus a deferred ESM binding `hello.wasip1-deferred.js` with `instantiate()` / `createInstance()` / `dispose()` | Single-threaded, unshared imported memory |
| `wasm32-wasip1-threads` | `hello.wasm32-wasi.wasm`   | `hello.wasi.cjs`                                                                                                                   | Shared memory with a worker pool          |

Both are passed to Zig as `-Dtarget=wasm32-wasi` (Zig only knows that spelling). The threaded flavor additionally passes `-Dcpu=baseline+atomics+bulk_memory+mutable_globals`, which is also the flag that selects the flavor.

Async work and thread-safe functions come from the `@emnapi/core` plugins in both flavors; the threaded flavor runs them on the plugin's JavaScript worker threads through the `emnapi_async_worker_create` / `emnapi_async_worker_init` exports. That is deliberately **not** napi-rs' implementation, which links emnapi's full C composition and uses the uv/libuv thread pool over real wasi pthreads: Zig 0.17 cannot build a multithreaded wasm module, so a zig-napi WASI addon has no libuv/Tokio-style async API.

Memory stays a loader decision. The module imports memory with the linker minimum (257 pages by default) and a 4 GiB maximum, and the loader's `wasm.initialMemory` (4000 pages by default) must stay below `wasm.maximumMemory`, because the Zig allocator grows the linear memory past its current size. A **single** allocation is capped at 1 GiB − 64 KiB (a wasm32 bump-allocator size-class limit: `malloc` and Zig's `Allocator` return null or an out-of-memory error instead of trapping above it, and a failed `realloc` keeps the old block), while the total memory can still be 4 GiB across many allocations.

Build-side overrides: `-Dwasi-initial-memory-pages=<pages>`, `-Dwasi-max-memory-pages=<pages>`, `-Dwasi-stack-size=<bytes>`, plus `-Demnapi-link-dir=<dir>` (or `EMNAPI_LINK_DIR`) and `-Demnapi-archive=<name-or-path>` to select a different emnapi archive.

## Examples

The simplest OpenHarmony example lives in `examples/basic`:

```bash
# Build all targets
zig build

# Build a single target
zig build -Dtarget=aarch64-linux-ohos
```

The output is `libhello.so` under `zig-out`.

The Node.js/WASI example lives in `examples/node`:

```bash
cd examples/node
pnpm build
pnpm test
```

It installs the addon as `zig-out/node/hello.<platform-arch-abi>.node`, for example `hello.darwin-arm64.node`, `hello.linux-x64-gnu.node`, or `hello.win32-x64-msvc.node`. For WASI threads, use `zig-napi build --target wasm32-wasip1-threads`; the CLI maps that to Zig's `wasm32-wasi` target with atomics/shared-memory features, and the output follows napi-rs naming as `hello.wasm32-wasi.wasm`.

Run the bundled Node example from the repository root:

```bash
pnpm install
pnpm run node-example:package
pnpm --filter zig-napi-node-example run test
```

Additional examples cover custom allocators (`examples/allocator-builtin`, `examples/allocator-custom`), memory behavior (`examples/memory`), scaffolding output (`examples/init`), and benchmarks (`examples/benchmark`). Build the OpenHarmony variants of all of them with:

```bash
pnpm run build:examples
```

## Testing

`node-test` mirrors the NAPI-RS example split with two independent demos:

- `node-test/napi-compat-mode` covers compat-mode style APIs and runtime-gated N-API v4/v5/v6/v7/v8 scenarios.
- `node-test/napi` covers the non compat-mode example surface such as values, strict validation, async, ThreadSafeFunction, and worker-thread loading.

The Node addon CI runs those tests on Linux, macOS, and Windows for Node.js 12, 14, 16, 18, 20, 22, and 24. It also builds `wasm32-wasip1-threads` addons and runs `node-test` with `NAPI_RS_FORCE_WASI=error` to verify the napi-rs-compatible wasm runtime path.

```bash
# Native test matrix
pnpm run test:node-matrix

# Build and test the matrix directly
pnpm run test:node-matrix:build
pnpm run test:node-matrix:run
```

OHOS runtime regression uses the [QEMU HAP pipeline](https://github.com/openharmony-zig/zig-napi/blob/main/docs/QEMU_E2E.md):

```bash
pnpm test:e2e:qemu -- <runner arguments>
```

Node.js native addons and WASI products run directly on the host:

```bash
pnpm test:e2e:node --output zig-out/e2e-node
```

See [`node-test/README.md`](https://github.com/openharmony-zig/zig-napi/blob/main/node-test/README.md) for the addon list, the WASI flavor layout, and the native/WASI test commands.

## Compatibility with napi-rs

The 2026-10-06 baseline is napi-rs `a713fcb` (`napi` 3.14.1, CLI 3.10.12, wasm-runtime 1.2.7). New bindings cover captured closures, typed Promise/iterator/stream protocols, owned collections and JSON, shared/weak references, native Promise waiting, class identity, export metadata, and TSFN callback results. See [the parity inventory](https://github.com/openharmony-zig/zig-napi/blob/main/docs/NAPI_RS_PARITY.md) for APIs, ownership rules, and platform boundaries.

## Documentation website

The documentation website lives in `website` and is a static [Astro](https://astro.build) site: the API documents are rendered to HTML at build time, and no framework runtime is shipped to the browser.

The published site is available at <https://openharmony-zig.github.io/zig-napi/>.

```bash
pnpm install

pnpm run website:dev      # dev server on http://127.0.0.1:4321
pnpm run website:build    # astro check + static build into website/dist
pnpm run website:preview  # serve the built output
pnpm run website:test     # static acceptance tests over website/dist
```

`pnpm run website:build` builds for a domain root. Deploying under a repository sub-path uses the same build with `SITE_BASE_PATH=/<repo>/` (see `.github/workflows/website.yml`), which the pages, assets, and cross-document links all follow. See [`website/README.md`](https://github.com/openharmony-zig/zig-napi/blob/main/website/README.md) for content editing, the browser test, and the visual system.

## Credits

This project is heavily inspired by:

- [napi-rs](https://github.com/napi-rs/napi-rs)
- [node-addon-api](https://github.com/nodejs/node-addon-api)
- [tokota](https://github.com/kofi-q/tokota)

## License

[MIT](./LICENSE)
