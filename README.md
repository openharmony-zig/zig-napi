# zig-napi

This project can help us to build native module libraries for OpenHarmony/HarmonyNext ArkTS and Node.js with zig-lang.

## Require

For openharmony, we must use a patched zig library to build. See detail with [zig-patch](https://github.com/openharmony-zig/zig-patch).

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

It installs the addon as `zig-out/node/hello.<platform-arch-abi>.node`, for example `hello.darwin-arm64.node`, `hello.linux-x64-gnu.node`, or `hello.win32-x64-msvc.node`.

The package also provides a `zig-napi` CLI for Node.js addons. Zig-specific commands such as `new` and `build` are implemented by this project. Packaging commands reuse the community `@napi-rs/cli` API for npm package directory creation, artifact collection, and pre-publish processing.

Create a new Node addon project:

```bash
pnpm install
pnpm --filter zig-napi cli new ../../my-addon --name my-addon --addon my_addon
cd my-addon
pnpm install
pnpm build
pnpm test
```

`zig-napi new` uses the same default target behavior as napi-rs. Pass `--targets <triple>` repeatedly or as a comma-separated list to choose the generated package targets manually, or pass `--enable-all-targets` to enable every napi-rs target known to the CLI.

Run the bundled Node example:

```bash
pnpm install
pnpm run node-example:package
pnpm --filter zig-napi-node-example run test
```

`zig-napi create-npm-dirs` calls `@napi-rs/cli`'s `createNpmDirs` API and creates `npm/<platform-arch-abi>` packages from the `napi` field in `package.json`. `zig-napi artifacts --output-dir zig-out/node` calls the community `artifacts` API and copies Zig's `<binary>.<platform-arch-abi>.node` outputs into those packages and into the root package. `zig-napi pre-publish` calls the community `prePublish` API to update optional dependencies and handle publish preparation.

Upstream `napi build` and `napi new` are not used directly for Zig addons because they currently expect Cargo projects and napi-rs' Rust templates.

Node.js matrix tests live in `node-test`. It mirrors the NAPI-RS example split with two independent demos:

- `node-test/napi-compat-mode` covers compat-mode style APIs and runtime-gated N-API v4/v5/v6/v7/v8 scenarios.
- `node-test/napi` covers the non compat-mode example surface such as values, strict validation, async, ThreadSafeFunction, and worker-thread loading.

The Node addon CI runs those tests on Linux, macOS, and Windows for Node.js 12, 14, 16, 18, 20, and 22.

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
