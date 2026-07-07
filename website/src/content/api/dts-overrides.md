---
title: d.ts Overrides
---

# d.ts Overrides

`dts` and `Dts` override only the generated TypeScript declaration. Runtime behavior stays unchanged.

## `dts`

```zig
napi.dts(value: anytype, comptime TypeScriptType: []const u8)
```

Use `dts` when you already have a value and want the generated declaration to use a custom TypeScript type string.

```zig
const napi = @import("napi");

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

pub const custom_add =
    napi.dts(add, "(left: Number, right: Number) => Number");
```

During runtime compilation, `custom_add` is the original `add` value. During declaration generation, the generator emits the provided type string.

## `Dts`

```zig
napi.Dts(comptime Value: type, comptime TypeScriptType: []const u8) type
```

Use `Dts` in signatures when the return type needs a TypeScript-facing override.

```zig
pub fn label() napi.Dts([]const u8, "String") {
    return napi.dts("zig-napi", "String");
}
```

In normal runtime builds, `Dts(Value, TypeScriptType)` is exactly `Value`. In declaration-generation builds, it becomes a wrapper carrying:

| Field          | Use                                                         |
| -------------- | ----------------------------------------------------------- |
| `is_napi_dts`  | Marker consumed by the conversion and tsgen layers.         |
| `wrapped_type` | Original Zig type.                                          |
| `ts_type`      | TypeScript text to emit.                                    |
| `value`        | Runtime value, when the wrapped value is not comptime-only. |

The wrapper exposes `unwrap()` during declaration-generation builds. Most addon code should not need it because conversion unwraps `Dts` automatically.

## Comptime Values

`dts` also supports comptime-only values such as function values, types, comptime integers, comptime floats, and enum literals. In declaration-generation mode those wrappers carry only type metadata, because such values cannot be stored as runtime fields.

## Type String Rules

The type string is emitted verbatim.

| Input                                       | Generated declaration intent                                        |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `"String"`                                  | Use the boxed or project-specific `String` name exactly as written. |
| `"string"`                                  | Use the TypeScript primitive.                                       |
| `"(left: Number, right: Number) => Number"` | Replace a function declaration with an explicit callable type.      |
| `"ReadonlyArray<string>"`                   | Use a richer TypeScript utility type.                               |

Because the string is not parsed by Zig, keep it valid TypeScript.
