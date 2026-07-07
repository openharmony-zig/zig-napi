---
title: Binary Data
---

# Binary Data

Binary wrappers make ownership and copying explicit at the JavaScript boundary.

## `Buffer`

```zig
napi.Buffer
```

Use `Buffer` for Node-compatible binary data.

| Constructor                                        | Behavior                                                          |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| `Buffer.New(env, len)`                             | Allocate a new mutable buffer.                                    |
| `Buffer.copy(env, data)`                           | Copy bytes into a new buffer.                                     |
| `Buffer.from(env, data)`                           | Wrap mutable data and transfer ownership to JavaScript.           |
| `Buffer.fromWithFinalizer(env, data, on_finalize)` | Wrap mutable data and run a callback when JavaScript releases it. |
| `Buffer.from_raw(env, raw)`                        | Wrap an existing `napi_value`.                                    |

Read the memory with:

| Method           | Use                     |
| ---------------- | ----------------------- |
| `asSlice()`      | Mutable `[]u8`.         |
| `asConstSlice()` | Immutable `[]const u8`. |
| `length()`       | Byte length.            |

When external buffers are not allowed by the runtime, creation falls back to copied buffers where the implementation can safely do so.

## `ArrayBuffer`

```zig
napi.ArrayBuffer
```

`ArrayBuffer` mirrors the buffer API for JavaScript `ArrayBuffer` values.

| Constructor                                             | Behavior                                                |
| ------------------------------------------------------- | ------------------------------------------------------- |
| `ArrayBuffer.New(env, len)`                             | Allocate a new ArrayBuffer.                             |
| `ArrayBuffer.copy(env, data)`                           | Copy bytes into a new ArrayBuffer.                      |
| `ArrayBuffer.from(env, data)`                           | Wrap mutable data and transfer ownership to JavaScript. |
| `ArrayBuffer.fromWithFinalizer(env, data, on_finalize)` | Wrap mutable data and run a callback when released.     |
| `ArrayBuffer.from_raw(env, raw)`                        | Wrap an existing `napi_value`.                          |

| Method                         | Use                                                 |
| ------------------------------ | --------------------------------------------------- |
| `asSlice()` / `asConstSlice()` | Access bytes.                                       |
| `length()`                     | Byte length.                                        |
| `detach()`                     | Detach the ArrayBuffer. Requires Node-API v7.       |
| `isDetached()`                 | Check whether it is detached. Requires Node-API v7. |

## `TypedArray`

```zig
napi.TypedArray(T)
```

Typed arrays can be created from new memory, copied memory, external memory, or a view into an existing `ArrayBuffer`.

| Constructor                                                         | Behavior                                                   |
| ------------------------------------------------------------------- | ---------------------------------------------------------- |
| `TypedArray(T).New(env, len)`                                       | Allocate an ArrayBuffer and create the view.               |
| `TypedArray(T).copy(env, data)`                                     | Copy numeric data into a new view.                         |
| `TypedArray(T).from(env, data)`                                     | Wrap mutable numeric data through an external ArrayBuffer. |
| `TypedArray(T).fromArrayBuffer(env, arraybuffer, len, byte_offset)` | Create a view over an existing ArrayBuffer.                |
| `TypedArray(T).from_raw(env, raw)`                                  | Wrap an existing TypedArray.                               |

| Method                         | Use                    |
| ------------------------------ | ---------------------- |
| `asSlice()` / `asConstSlice()` | Access typed elements. |
| `length()`                     | Element length.        |
| `byteLength()`                 | Byte length.           |

Aliases are exported for common element types:

| Alias                              | Element                    |
| ---------------------------------- | -------------------------- |
| `Int8Array`                        | `i8`                       |
| `Uint8Array`                       | `u8`                       |
| `Uint8ClampedArray`                | `u8` with clamped raw type |
| `Int16Array` / `Uint16Array`       | `i16` / `u16`              |
| `Int32Array` / `Uint32Array`       | `i32` / `u32`              |
| `Float32Array` / `Float64Array`    | `f32` / `f64`              |
| `BigInt64Array` / `BigUint64Array` | `i64` / `u64`              |

BigInt typed arrays require Node-API v6 or newer.

## `DataView`

```zig
napi.DataView
```

`DataView` supports byte-level access and explicit endianness.

| Constructor                                                            | Behavior                                            |
| ---------------------------------------------------------------------- | --------------------------------------------------- |
| `DataView.New(env, byte_length)`                                       | Allocate a new ArrayBuffer and view.                |
| `DataView.copy(env, data)`                                             | Copy bytes into a new view.                         |
| `DataView.from(env, data)`                                             | Wrap mutable bytes through an external ArrayBuffer. |
| `DataView.fromArrayBuffer(env, arraybuffer, byte_offset, byte_length)` | Create a view over an existing ArrayBuffer.         |
| `DataView.from_raw(env, raw)`                                          | Wrap an existing DataView.                          |

| Method                                                                                | Use                            |
| ------------------------------------------------------------------------------------- | ------------------------------ |
| `asSlice()` / `asConstSlice()`                                                        | Access bytes.                  |
| `byteLength()`                                                                        | View byte length.              |
| `readInt(T, offset, little_endian)` / `writeInt(T, offset, value, little_endian)`     | Generic integer access.        |
| `readFloat(T, offset, little_endian)` / `writeFloat(T, offset, value, little_endian)` | Generic floating-point access. |
| `getInt8` / `getUint8`                                                                | 8-bit reads.                   |
| `getInt16` / `getUint16` / `getInt32` / `getUint32`                                   | Endian-aware integer reads.    |
| `getBigInt64` / `getBigUint64`                                                        | 64-bit integer reads.          |
| `getFloat32` / `getFloat64`                                                           | Endian-aware float reads.      |
| `setInt8` / `setUint8`                                                                | 8-bit writes.                  |
| `setInt16` / `setUint16` / `setInt32` / `setUint32`                                   | Endian-aware integer writes.   |
| `setBigInt64` / `setBigUint64`                                                        | 64-bit integer writes.         |
| `setFloat32` / `setFloat64`                                                           | Endian-aware float writes.     |
