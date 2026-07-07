---
title: Versioning
---

# Versioning

`zig-napi` defaults to Node-API v8 for OpenHarmony and Node addon builds.

## `NapiVersion`

```zig
napi.NapiVersion
napi_build.NapiVersion
```

Supported values:

```zig
.v1
.v2
.v3
.v4
.v5
.v6
.v7
.v8
.v9
.v10
.experimental
```

## Configure Version

Pass `.node_api` to build helpers:

```zig
.node_api = .{
    .version = .v10,
    .experimental = false,
},
```

When `.experimental = true`, the addon requests the experimental Node-API version and enables experimental declarations in `napi-sys`.

## Version-Gated Wrappers

| Wrapper                                         | Minimum     |
| ----------------------------------------------- | ----------- |
| `Async`                                         | Node-API v4 |
| `AsyncWithEvents`                               | Node-API v4 |
| `ThreadSafeFunction`                            | Node-API v4 |
| `Env.createDate`                                | Node-API v5 |
| `Object.isDate` / `Object.dateValue`            | Node-API v5 |
| `BigInt`                                        | Node-API v6 |
| `BigInt64Array` / `BigUint64Array`              | Node-API v6 |
| `ArrayBuffer.detach` / `ArrayBuffer.isDetached` | Node-API v7 |
| `Object.freeze` / `Object.seal`                 | Node-API v8 |

If the selected version is too low, wrappers fail at compile time with a message that points back to `.node_api.version`.

## Helper Functions

```zig
napi.selectedNapiVersion()
napi.experimentalEnabled()
napi.selectedNapiVersion().isAtLeast(.v6)
napi.resolveRequestedRuntime(runtime)
```

Use these when low-level code needs to inspect the compiled runtime mode.

Wrapper code uses compile-time version checks internally. Addon code usually only needs `selectedNapiVersion` or `isAtLeast` when it has custom low-level branches.

`napi_build.NodeApiOptions` is the build-side configuration struct:

```zig
.node_api = .{
    .version = .v8,
    .experimental = false,
}
```

`experimental = true` uses the experimental Node-API version number even when `version` is set.
