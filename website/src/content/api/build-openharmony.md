---
title: OpenHarmony Build
---

# OpenHarmony Build

Use `nativeAddonBuild` from `@import("zig-napi").napi_build` to build OpenHarmony shared libraries.

## `nativeAddonBuild`

```zig
napi_build.nativeAddonBuild(
    build: *std.Build,
    option: NativeAddonBuildOptionsWithModule,
) !NativeAddonBuildResult
```

Minimal build file:

```zig
const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");

    _ = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .napi_module = napi,
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
}
```

## Targets

The helper knows the supported OpenHarmony target triples:

| Output slot | Target |
| --- | --- |
| `arm64` | `aarch64-linux-ohos` |
| `arm` | `arm-linux-ohoseabi` |
| `x64` | `x86_64-linux-ohos` |

`NativeAddonBuildResult` stores the compile step for each enabled target.

If `root_module_options.target` is an OpenHarmony target, the helper builds only the matching output slot. Otherwise it builds all supported OpenHarmony targets.

## Options

`NativeAddonBuildOptionsWithModule` accepts:

| Field | Use |
| --- | --- |
| `name` | Shared library name. |
| `napi_module` | Optional `zig-napi` module import. Required when `.node_api` is customized. |
| `node_api` | Node-API version and experimental mode passed into the wrapper module. |
| `root_module_options` | Source file, target, optimize mode, imports, libc/cpp flags, and other Zig module options. |
| `version` | Optional semantic version for the shared library. |
| `max_rss` | Build step memory limit. |
| `use_llvm` / `use_lld` | Override Zig backend/linker selection. |
| `zig_lib_dir` | Optional Zig lib directory. |
| `win32_manifest` | Passed through for API parity with library options. |

The helper clones the provided root module options for each target and injects configured `build_options` plus the configured `napi` import.

## SDK Resolution

The helper resolves the OHOS native SDK from:

- `OHOS_NDK_HOME`, using `$OHOS_NDK_HOME/native`
- `ohos_sdk_native`

It then links `ace_napi.z`, enables libc, and adds the platform include and library directories.

## Node-API Options

OpenHarmony builds use Node-API v8 by default. If the addon exports wrappers gated by a newer Node-API version, pass `.node_api` and also pass `.napi_module = napi`.

```zig
.node_api = .{
    .version = .v10,
    .experimental = false,
},
```

Passing `napi_module` lets the configured version flow into both the addon root module and the `napi` wrapper module.

## ArkVM Host Test Mode

Passing `-Darkvm-test=true` builds a host Linux x64 artifact under `zig-out/arkvm-host`. This is intended for ArkVM host tests where device-only OpenHarmony libraries should not be linked.

## Helper Functions

| Helper | Use |
| --- | --- |
| `resolveNdkPath(build)` | Returns `$OHOS_NDK_HOME/native`, `ohos_sdk_native`, or an empty string. |
| `cloneLibraryOptions(build, option, target)` | Reuses addon library options for a resolved target. |
