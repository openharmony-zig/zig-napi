---
title: Primitive Values
---

# Primitive Values

Primitive wrappers can be used directly, and they are also used by automatic argument and return conversion.

## `NapiValue`

```zig
napi.NapiValue
```

`NapiValue` is the escape hatch for raw JavaScript values. It stores `env` and `raw`, and can reinterpret the value through the conversion layer with `As(T)`.

Use it when the public API needs to pass a value through without committing to a narrower wrapper.

```zig
pub fn read(value: napi.NapiValue) !i32 {
    return value.As(i32);
}
```

## Number, Bool, String, BigInt

| Wrapper       | Typical Zig values                                      |
| ------------- | ------------------------------------------------------- |
| `napi.Number` | integers, floats, comptime numeric values               |
| `napi.Bool`   | `bool`                                                  |
| `napi.String` | UTF-8 or UTF-16 string-like values                      |
| `napi.BigInt` | integer values that should cross as JavaScript `bigint` |

`BigInt` requires Node-API v6 or newer.

## `Number`

`Number.New(env, value)` accepts integer, float, `comptime_int`, and `comptime_float` values that fit JavaScript number conversion. Signed integers up to 32 bits use `napi_create_int32`; unsigned integers up to 32 bits use `napi_create_uint32`; `i64` uses `napi_create_int64`; floats use double conversion.

Use `BigInt` for `i128`, `u128`, and values that should not be represented as JavaScript numbers.

Integer inputs reject fractions, non-finite numbers and out-of-range values with
JavaScript errors. `u64`/`usize` outputs use a double, without narrowing to `i64`;
use BigInt when exact values above `2^53 - 1` matter.

## `String`

`String.New(env, bytes)` creates a UTF-8 JavaScript string.

| Method        | Use                                            |
| ------------- | ---------------------------------------------- |
| `utf8Len()`   | Byte length of the UTF-8 representation.       |
| `utf16Len()`  | Code-unit length of the UTF-16 representation. |
| `copyUtf8()`  | Allocate and return `[]u8`.                    |
| `copyUtf16()` | Allocate and return `[]u16`.                   |

Automatic conversion supports UTF-8 and UTF-16 string-like Zig targets.

The length/copy methods are fallible (`try value.copyUtf8()`, for example).
Manual copies must be released with the allocator that created them.

## `BigInt`

`BigInt.from_napi_value(env, raw, T)` is fallible and supports `i64` and `u64`
extraction. The conversion layer uses checked `BigInt.create` for `i128` and
`u128` returns. `create` also accepts integer widths up to 64 bits.

## Null And Undefined

```zig
napi.Null.New(env)
napi.Undefined.New(env)
```

Use these wrappers when a manual API needs to return JavaScript `null` or `undefined` explicitly.

## Direct Constructors

Most wrappers expose `New` or `from_raw`:

```zig
const value = napi.String.New(env, "hello");
const undefined_value = napi.Undefined.New(env);
```

For regular exported functions, returning ordinary Zig values is usually clearer than constructing wrappers manually.

For recoverable failures, prefer `try Number.create`, `try Bool.create`,
`try BigInt.create`, `try String.createUtf8`/`createUtf16`, `try Null.create`
and `try Undefined.create`. Their legacy `New` forms keep their signatures and
panic if construction fails; generated conversions use the fallible forms.
