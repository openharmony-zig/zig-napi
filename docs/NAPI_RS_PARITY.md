# napi-rs parity

The baseline for this branch is [napi-rs a713fcb](https://github.com/napi-rs/napi-rs/tree/a713fcb377ee28be5abd7b6a560e3eb4f31444ca), checked on 2026-10-06: `napi` 3.14.1, `napi-derive` 3.6.11, `napi-sys` 3.4.0, CLI 3.10.7 and wasm-runtime 1.2.5. The CLI and runtime are pinned to those versions. The emnapi ABI remains pinned to 2.0.0-alpha.5; updating it independently would change the linked archive/runtime contract.

The CLI executable in `bin/zig-napi.js` loads the maintained CommonJS source modules in `lib/`. Binding-target metadata, declaration handling and worker crash reporting are adapted directly from the corresponding upstream TypeScript source files, with source paths and the pinned revision recorded in each module. Upstream notices ship in `licenses/NAPI-RS-LICENSE`. The CLI handles Node.js/WASI; OHOS builds and SDK HAP signing remain in the separate QEMU pipeline.

## Capabilities and regression coverage

| Capability | Zig API / implementation | Regression |
| --- | --- | --- |
| Primitive values, BigInt, nullable/optional shapes and Either-style alternatives | Zig scalars, optionals, tagged unions, checked numeric conversion | Existing native suites and OHOS primitives/unions groups |
| Buffers, ArrayBuffer, all typed arrays, DataView, external storage | Existing wrappers with empty-view, offset and finalizer checks | Native binary suites and OHOS binary/memory groups |
| Own object properties | `Object.Define`, `DefineProperty`; exports and converted objects use data descriptors | Inherited setter, `__proto__`, descriptor and null-handle cases |
| UTF-8, UTF-16 and Latin1 | Correct byte/code-unit lengths; owned external Latin1/UTF16 strings | Embedded NUL, astral Unicode, empty input, copying fallback |
| Function invocation and captured closures | `Apply`, `Bind`, `NewInstance`, `name`, `NewClosure` | Receiver, constructor, independent state, original thrown value, failed conversion |
| JS Promise consumption | `PromiseOf(T).then`, `catchError`, `finally` | Fulfillment, rejection and thrown-value identity |
| Native workers awaiting JS Promises | `NativePromise(T).wait(context.io)` | Delayed fulfillment, type/rejection errors and Worker termination |
| Native collection and JSON conversion | `StringMap(V)`, `Set(T)`, owned recursive `Json` | Own keys, nested input, nonfinite/cyclic rejection, async deep clones, rollback |
| Iterators and async generators | `Iterator(T)`, `AsyncIterator(T)`, `Iteration(T)` | JS consumers/producers, native producers, next/return/throw, extracted methods |
| Web Streams | Typed readable/writable streams, reader/writer methods, native readable pull producer | Node host streams/backpressure; OHOS standard stream protocols |
| Strong/weak shared references | `SharedReference(T)`, `WeakReference(T)` | Independent owners, actual native thread disposal, GC and Worker termination |
| Type-safe class instances | `ClassInstance(T)`, `FactoryClassInstance(T)` | Type tags/provenance, foreign values, prototype forgery, renamed/namespaced classes |
| Export attributes and type-only schemas | Declaration-only public object schemas; root/class/object `napi_config` with `ExportOptions` | Name, namespace, skip, readonly, nullable, descriptors, getter/setter |
| Date, Symbol and callback receivers | `Date`, `Symbol`, `Symbol.For`, `Env.symbolFor`, `This(T)` | Identity, registry identity, native method receiver |
| Explicit discriminants | `TaggedUnion(T, tag, payload)` | Distinct tags with overlapping payload types and invalid-input rollback |
| Environment lifecycle | Script evaluation, external memory accounting, instance data, cleanup hooks and scopes | Removable/idempotent hooks, replacement refusal, escaped handle |
| TSFN callback results | Builder, weak/capped queues, `CallWithReturnValue`, `CallAsync`, `CallAsyncCatch` | Typed results, returned Promise adoption, queue-full, blocking drain and abort wake |
| OHOS bounded TSFN queues | Independent capacity ledger for the SDK's off-by-one queue check | Limit 1 rejects a second nonblocking call; native blocked producers wake on abort |
| Async lifecycle and module retention | Shared native runtime, cancellation, events, native image pin | Environment teardown, late producers, nested events, owned payloads |
| WASI allocator/crash lifecycle | Heap refresh, crash flags before cleanup, fatal quarantine, latched dispose rejection | Both flavors, concurrent growth, OOM preservation and real worker trap/natural exit |
| CLI packaging and build | Upstream JS bindings/version/universalize plus Zig build/new/rename/watch for Node.js/WASI | Real packed fresh install, native/WASI builds, ESM, custom output, universal artifact load, early OHOS-target rejection |
| TypeScript declarations | Namespaced class emission, wrapper/TSFN return types, zero-arg functions, CJS rebase/barrier, target markers | TypeScript 6 strict compile of real generated declarations and consumer contracts |

Shared native fixtures are in `examples/basic/src/parity.zig`. Node runs them through `node-test/napi/__tests__/parity.spec.js`; OHOS uses `test/parity.spec.ts` inside a signed UIAbility HAP. The existing suites remain part of the full regression.

## Ownership contracts

- Plain JS wrappers are borrowed and must be used on their environment thread. `Reference(T)` is a single-owner legacy handle; call `Unref`/`Delete` once. Its conversion validates `T`, even on Node-API 10 where primitive references are allowed.
- `SharedReference` and `WeakReference` require `Clone()` for each owner. A struct copy does not acquire ownership. Each owner calls `Close()` once. Native threads may clone/close; reads and strong/weak conversion stay on the environment thread. Final engine disposal is dispatched through an unreferenced TSFN.
- `NativePromise(T)` accepts JS Promises as native input. It copies native data, allows one pending waiter, wakes on cancellation/environment teardown, and returns a value borrowed until `Close()`. Nested JS handles cannot cross to the worker. Rejections become owned native error snapshots.
- `NewClosure` owns its captured context after successful creation and invokes a declared `deinit` when collected. Native producer methods retain shared state independently, including when a method is extracted from its iterator.
- TSFN calls transfer payload ownership on every path, including queue-full, closing and allocation failures. Return-value completion receives a borrowed result. `CallAsync` must run on the environment thread; returned JS Promises are adopted by its deferred.
- External strings own a duplicate of their input. WASI Latin1 creation widens to UTF16 to preserve embedded NUL despite emnapi alpha.5's encoder. On WASI or a host/API without the N-API 10 external-string calls, creation copies normally and reports `copied: true`.
- Return newly allocated native values as `Owned(T)`. Returning an input alias or literal as a plain value is borrowed. `napi_custom` conversion hooks can supply `napi_clone` and `napi_deinit` for owned custom types. Skipped object fields require defaults; those defaults stay borrowed and are restored during deep cloning.

## Platform boundaries

The goal is equivalent binding behavior on supported hosts. Rust proc macros, Cargo, Tokio futures and Rust-specific standard-library types are expressed using Zig comptime exports, the Zig CLI, `Async`/`std.Io`, and explicit native wrappers. They are not Rust compatibility APIs.

Zig 0.16 has no usable native evented `std.Io` backend here; `.event` resolves to the threaded backend. WASI async work/TSFN run through emnapi's JS worker plugins. WASI does not provide native `std.Thread`/Tokio pthread semantics, so native-thread reference tests and `NativePromise.wait` are native-target capabilities. WASI worker crash and allocator behavior have separate real WASM acceptance tests.

OHOS APIs follow the installed SDK headers. Registry symbols use `Symbol.for` when the N-API call is unavailable. External strings report a copying fallback. Stream consumers require standard methods; `ReadableStream.New` also requires the host's global `ReadableStream` constructor. OHOS QEMU verifies the native protocol against its actual host; Node additionally verifies actual Web Stream construction and backpressure.

The default native API remains v8. `node-test` supports `-Dnapi-version=10` to exercise modern APIs without raising the minimum version of existing addons. Node-API version selection and experimental APIs remain compile-time gates.

See [QEMU E2E](QEMU_E2E.md) for the mandatory real-guest validation pipeline and evidence format.

The original parity run is recorded in [qemu-e2e-results.json](qemu-e2e-results.json). The Node-only CLI source migration has a separate full matrix report in [cli-refactor-e2e-results.json](cli-refactor-e2e-results.json).
