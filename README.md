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
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });

    if (result.arm64) |arm64| {
        arm64.root_module.addImport("napi", napi);
    }
    if (result.arm) |arm| {
        arm.root_module.addImport("napi", napi);
    }
    if (result.x64) |x64| {
        x64.root_module.addImport("napi", napi);
    }
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

Node addons request Node-API v8 by default. To request a newer runtime API version or experimental Node-API, configure `node_api` in `nodeAddonBuild`:

```zig
.node_api = .{
    .version = .v10,
    .experimental = false,
},
```

When `.experimental = true`, the addon requests Node-API experimental version and enables experimental declarations in `napi-sys`.

Version-gated APIs follow the same shape as NAPI-RS feature gates: for example `ThreadSafeFunction` and `Async` require v4, while `BigInt` requires v6. If an addon selects a lower version, those wrappers fail at compile time with a message pointing back to `.node_api.version`.

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
zig build
node test.js
```

It installs the addon as `zig-out/node/hello.<platform-arch-abi>.node`, for example `hello.darwin-arm64.node`, `hello.linux-x64-gnu.node`, or `hello.win32-x64-msvc.node`.

Node.js matrix tests live in `node-test`. It mirrors the NAPI-RS example split with two independent demos:

- `node-test/napi-compat-mode` covers compat-mode style APIs and runtime-gated N-API v4/v5/v6/v7/v8 scenarios.
- `node-test/napi` covers the non compat-mode example surface such as values, strict validation, async, ThreadSafeFunction, and worker-thread loading.

The Node addon CI runs those tests on Linux, macOS, and Windows for Node.js 12, 14, 16, 18, 20, and 22.

## Credits

This zig-napi project is heavily inspired by:

- [napi-rs](https://github.com/napi-rs/napi-rs)
- [node-addon-api](https://github.com/nodejs/node-addon-api)
- [tokota](https://github.com/kofi-q/tokota)

## LICENSE

[MIT](./LICENSE)
