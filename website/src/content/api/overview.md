---
title: API Overview
---

# API Overview

`zig-napi` exposes two public import surfaces:

| Import | Use |
| --- | --- |
| `@import("napi")` | Runtime wrappers, module registration, conversion helpers, async descriptors, and TypeScript override wrappers. |
| `@import("zig-napi").napi_build` | `build.zig` helpers for OpenHarmony shared libraries, Node.js `.node` addons, and generated declaration files. |

The normal flow is:

1. Export Zig functions, constants, classes, and wrappers from a root struct.
2. Register that root with `napi.NODE_API_MODULE`.
3. Build an OpenHarmony library with `nativeAddonBuild`, a Node addon with `nodeAddonBuild`, or both.
4. Run `generateTypeDefinition` when the JavaScript consumer needs an `index.d.ts`.

## Public Modules

`napi.zig` re-exports the wrappers that addon code is expected to use. Most users should import from `napi` instead of importing files under `src/napi/**` directly.

```zig
const napi = @import("napi");

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
```

## Runtime And Type Generation

Runtime builds and declaration generation compile the same addon root in different modes. `napi.dts` and `napi.Dts` only wrap values during declaration generation; at runtime they preserve the original value shape.

Use this when the Zig type is useful internally but the public TypeScript contract should be narrower, wider, or named differently.

## Runtime Surface

The `napi` module re-exports the runtime-facing API:

| Category | Exports |
| --- | --- |
| Environment and raw values | `Env`, `NapiValue`, `napi_sys` raw Node-API bindings |
| Primitive values | `Number`, `String`, `Bool`, `BigInt`, `Null`, `Undefined` |
| Object values | `Object`, `Array`, `Promise` |
| Binary values | `Buffer`, `ArrayBuffer`, `TypedArray`, typed array aliases, `DataView` |
| Functions | `Function`, `FunctionRef`, `CallbackInfo`, `ThreadSafeFunction` |
| Async | `AsyncRuntime`, `Async`, `AsyncWithEvents`, `AsyncContext`, `CancelToken`, `AbortSignal`, `Worker` |
| Native state | `Class`, `ClassWithoutInit`, `Reference`, `Ref`, `ObjectRef`, `External`, `NativeWrap` |
| Errors | `Error`, `Status`, `Result`, `JsError`, `JsTypeError`, `JsRangeError` |
| Build-time behavior | `NapiVersion`, `selectedNapiVersion`, `experimentalEnabled`, `resolveRequestedRuntime` |
| TypeScript overrides | `dts`, `Dts` |
| Allocators | `globalAllocator`, `setOperationAllocator`, `resetOperationAllocator` |
| Registration | `NODE_API_MODULE`, `NODE_API_MODULE_WITH_INIT` |

## Build Surface

`@import("zig-napi").napi_build` exports the build helpers:

| Export | Use |
| --- | --- |
| `nativeAddonBuild` | Build OpenHarmony shared libraries. |
| `nodeAddonBuild` | Build platform-specific Node.js `.node` addons. |
| `generateTypeDefinition` | Generate `index.d.ts` from the addon root. |
| `NativeAddonBuildOptionsWithModule` | Options for OpenHarmony output. |
| `NodeAddonBuildOptionsWithModule` | Options for Node addon output. |
| `TypeDefinitionBuildOptions` | Options for declaration generation. |
| `NativeAddonBuildResult` | Compile steps for `arm64`, `arm`, and `x64`. |
| `NodeAddonBuildResult` | Node addon compile step. |
| `NodeApiOptions` | Node-API version and experimental mode. |
| `NapiVersion` | Build-time Node-API enum. |
| `resolveNdkPath` | Resolve the OpenHarmony native SDK path. |
| `cloneLibraryOptions` | Clone root module build options for another target. |
| `nodePlatformArchAbi` | Format Node platform/arch/ABI suffix. |
| `nodeAddonFilename` | Format the installed `.node` filename. |

## Read Order

Start with `Conversion Model` if you are exporting normal Zig functions. Use the value wrapper pages when you need manual `Env` or raw N-API work. Use `Ownership` when JavaScript values must carry native state or native code must hold references across calls.
