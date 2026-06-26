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
hello.wasm32-wasi.wasm
```

The helper exposes these utilities:

| Helper | Description |
| --- | --- |
| `nodePlatformArchAbi(build, target)` | Returns the platform-arch-abi suffix. |
| `nodeAddonExtension(target)` | Returns `node` for native targets and `wasm` for WASI. |
| `nodeAddonFilename(build, name, target)` | Returns the final `.node` or `.wasm` filename. |

## Target Selection

If `root_module_options.target` is omitted, the Node addon target defaults to the host target. Provide a target explicitly for cross builds.

For WASI threads builds, use the napi-rs target name through the CLI:

```bash
zig-napi build --target wasm32-wasip1-threads
```

The CLI maps that target to Zig's `wasm32-wasi` spelling with atomics/shared-memory CPU features. The helper normalizes the output to napi-rs' `wasm32-wasi` platform package name and installs `<binary>.wasm32-wasi.wasm`.

## Windows Linking

On Windows MSVC, Node-API symbols are resolved from the current Node.js process at runtime by default. If a build needs an import library, pass `.node_import_lib`, set `NODE_LIB_FILE`, or set `NODE_LIB_DIR`.

Windows GNU builds search `LIBNODE_PATH`, then `LIBPATH`, then `PATH` for `libnode.dll`.

## Options

`NodeAddonBuildOptionsWithModule` accepts:

| Field | Use |
| --- | --- |
| `name` | Base addon name. |
| `napi_module` | `zig-napi` module imported into the addon root. |
| `root_module_options` | Source file, target, optimize mode, imports, and Zig module options. |
| `node_api` | Node-API version and experimental mode. |
| `node_import_lib` | Optional Windows import library override. |
| `version` | Optional semantic version. |
| `max_rss` | Build step memory limit. |
| `use_llvm` / `use_lld` | Override Zig backend/linker selection. |
| `zig_lib_dir` | Optional Zig lib directory. |
| `win32_manifest` | Optional Windows manifest. |

The helper injects `build_options` into the addon root and configures `@import("napi")` with the selected Node-API version.

## Install Layout

The output is installed under `zig-out/node` with the formatted filename from `nodeAddonFilename`.

On Windows, the import library is installed into the same `node` directory when Zig produces one.

## Link Behavior

The compile step sets `linker_allow_shlib_undefined = true` so Node-API symbols can be resolved by the host runtime. Windows GNU builds still link `node` explicitly after locating `libnode.dll`.
