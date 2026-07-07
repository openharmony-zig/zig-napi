---
title: Declaration Generation
---

# Declaration Generation

`generateTypeDefinition` generates TypeScript declarations from the same root Zig file used by the runtime addon.

## `generateTypeDefinition`

```zig
napi_build.generateTypeDefinition(
    build: *std.Build,
    option: TypeDefinitionBuildOptions,
) !*std.Build.Step.Run
```

Example:

```zig
const dts = try napi_build.generateTypeDefinition(b, .{
    .root_source_file = b.path("./src/hello.zig"),
    .output = b.path("index.d.ts"),
    .napi_module = napi,
    .node_api = .{ .version = .v8 },
});
b.getInstallStep().dependOn(&dts.step);
```

## Keep Options In Sync

Use the same `.node_api` options for runtime builds and declaration generation. This matters when the exported API uses version-gated wrappers such as `ThreadSafeFunction`, `Async`, `BigInt`, or BigInt typed arrays.

`TypeDefinitionBuildOptions` accepts:

| Field              | Use                                                                              |
| ------------------ | -------------------------------------------------------------------------------- |
| `root_source_file` | Addon root source file to compile for reflection.                                |
| `output`           | Destination `.d.ts` path.                                                        |
| `napi_module`      | `zig-napi` module used to create the configured reflection imports.              |
| `node_api`         | Node-API version and experimental mode used by version-gated wrappers.           |
| `header`           | Optional text inserted after the generated banner comments.                      |
| `options`          | Optional extra `std.Build.Step.Options` module for addon-specific build options. |

## Supported Shapes

The generator maps the public export surface into TypeScript:

| Zig shape                                   | TypeScript shape                                                     |
| ------------------------------------------- | -------------------------------------------------------------------- |
| `pub fn`                                    | `export function`                                                    |
| primitives                                  | `number`, `string`, `boolean`, `bigint`, `null`, `undefined`         |
| object-like structs                         | `export interface`                                                   |
| tuples                                      | tuple types                                                          |
| arrays, slices, and `std.ArrayList(T)`      | `Array<T>`                                                           |
| optionals                                   | `T                                                                   | undefined | null` |
| enums                                       | `export declare const enum`                                          |
| string enums with `napi_string_enum = true` | string-valued `const enum`                                           |
| `union(enum)`                               | union of payload types                                               |
| `napi.Buffer`                               | `Buffer`                                                             |
| `napi.ArrayBuffer`                          | `ArrayBuffer`                                                        |
| `napi.DataView`                             | `DataView`                                                           |
| `napi.TypedArray(T)` aliases                | matching TypedArray names                                            |
| `napi.Promise`                              | `Promise<void>`                                                      |
| async descriptors                           | `Promise<T>`                                                         |
| `napi.AsyncWithEvents` return               | `Promise<T>` plus trailing `onEvent?: (event: Event) => void`        |
| `napi.Function`                             | function signatures                                                  |
| `napi.ThreadSafeFunction`                   | callback signature returning `void`                                  |
| `napi.Reference(T)`                         | declaration of `T`                                                   |
| `napi.External(T)`                          | `ExternalObject<T>` branded interface                                |
| `napi.AbortSignal`                          | local `AbortSignal` interface                                        |
| classes                                     | constructor, fields, instance methods, static methods, static values |
| returned functions                          | function signature with parameter names when source can be resolved  |

When the inferred public shape is not the desired public contract, use `napi.dts` or `napi.Dts`.

## Class Declarations

`napi.Class(T)` emits a public constructor. Constructor parameters come from `T.init` when present; otherwise each field becomes a constructor parameter.

`napi.ClassWithoutInit(T)` emits a private constructor. Static factory methods that return `T` or `*T` become constructors on the JavaScript side.

Struct fields become instance properties. Function declarations become instance methods when their first parameter is `*T` or `T`; otherwise they become static methods. Non-function declarations become `static readonly` values.

## Source Names

The generator scans the source file to recover parameter names for exported functions, class constructors, class methods, and returned callbacks. If a name cannot be recovered, it falls back to `arg`, `arg0`, `arg1`, and so on.

## Header Injection

`TypeDefinitionBuildOptions.header` can inject text after the generated banner. Use it for imports, global declarations, or package-specific comments that should live in the generated `.d.ts`.
