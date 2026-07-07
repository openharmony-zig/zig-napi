---
title: Module Registration
---

# Module Registration

Module registration is done at compile time. The root argument must be a struct type, usually `@This()` from the addon root file.

## `NODE_API_MODULE`

```zig
napi.NODE_API_MODULE(comptime name: []const u8, comptime root: type) void
```

Exports every public field and declaration on `root` into the JavaScript module export object.

```zig
const napi = @import("napi");

pub const version = "0.1.0";

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
```

The resulting JavaScript module has `version` and `add` exports.

## `NODE_API_MODULE_WITH_INIT`

```zig
napi.NODE_API_MODULE_WITH_INIT(
    comptime name: []const u8,
    comptime root: type,
    init: ?fn (env: napi.Env, exports: napi.Object) anyerror!?napi.Object,
) void
```

Use this form when the module needs custom setup after generated exports are attached.

```zig
fn init(env: napi.Env, exports: napi.Object) !?napi.Object {
    try exports.Set("loadedAt", env.createDate(0));
    return null;
}

comptime {
    napi.NODE_API_MODULE_WITH_INIT("hello", @This(), init);
}
```

Returning `null` keeps the generated export object. Returning an object replaces it.

## Export Rules

| Root member                          | Export behavior                                              |
| ------------------------------------ | ------------------------------------------------------------ |
| `pub fn` declaration                 | Converted into a JavaScript function.                        |
| `pub const` declaration              | Converted through the `Napi.to_napi_value` conversion layer. |
| public struct field on the root type | Converted and attached as an export.                         |
| `pub const` class wrapper            | Exported as a JavaScript class constructor.                  |
| `pub const` enum type                | Exported as a TypeScript enum during declaration generation. |
| `pub const napi_allocator`           | Reserved for allocator configuration and not exported.       |

If conversion fails during module initialization, the wrapper throws the pending JavaScript error into the current `Env`.

## Init Hook

The init hook runs after generated exports are attached.

```zig
fn init(env: napi.Env, exports: napi.Object) !?napi.Object {
    try exports.Set("global", try env.getGlobal());
    return null;
}
```

Return `null` to keep the generated export object. Return another `napi.Object` to replace `module.exports`.

## Type Generation Mode

When `build_options.napi_tsgen` is enabled by `generateTypeDefinition`, registration becomes a no-op at runtime. This lets the generator compile the addon root for reflection without emitting a native module initializer.

`napi.dts` and `napi.Dts` also switch behavior in this mode, so custom TypeScript text affects declarations without changing runtime exports.
