# zig-napi

This project can help us to build a native module library for OpenHarmony/HarmonyNext with zig-lang.

> Note: This project is still in the early stage of development and is not ready for use. You can use it as a toy.

## Install

We recommend you use ZON(Zig Package Manager) to install it.

```zon
// build.zig.zon
.{
    .name = "appname",
    .version = "0.0.0",
    .dependencies = .{
        .network = .{
            .url = "https://github.com/openharmony-zig/zig-napi/archive/refs/tags/<COMMIT_HASH_HERE>.tar.gz",
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

    const result = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .root_source_file = b.path("./src/hello.zig"),
        .target = target,
        .optimize = optimize,
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

Our goal is to provide a zig version similar to the `node-addon-api`.

- [x] Out of box building system.
- [ ] Macro for napi.

## Example

We provide a simple example to help you get started in `examples/add`.

Just run the following command to build the example:

```bash
# Build all targets
zig build

# Build single target
zig build -Dtarget=aarch64-linux-ohos
```

And you can get `libhello.so` in `zig-out`.

## Credits

This zig-napi project is heavily inspired by:

- [napi-rs](https://github.com/napi-rs/napi-rs)
- [node-addon-api](https://github.com/nodejs/node-addon-api)
- [tokota](https://github.com/kofi-q/tokota)

## LICENSE

[MIT](./LICENSE)
