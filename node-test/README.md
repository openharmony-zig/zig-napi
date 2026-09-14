# node-test

Node.js test matrix for the `zig-napi` addon surface. Every addon is built by
`build.zig` and loaded through `load-addon.js`, which resolves the platform
`.node` binary or one of the generated WASI loaders for the requested flavor.

## Layout

| Path                | Contents                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `napi-compat-mode/` | compat-mode style APIs and the runtime-gated N-API v4/v5/v6/v7/v8 scenarios                                                           |
| `napi/`             | non compat-mode surface: values, strict validation, async, thread-safe functions and worker-thread loading                            |
| `wasm/`             | WASI acceptance (`abi.test.cjs`, `concurrency.test.cjs`), the async lifecycle spec, the browser harness and the event-queue benchmark |
| `benchmarks/`       | diagnostic memory/throughput benchmarks, not part of the pass/fail matrix                                                             |

Addons declared in `package.json` → `napi.binaryNames`:

| Addon         | Source                         | Covers                                                                                |
| ------------- | ------------------------------ | ------------------------------------------------------------------------------------- |
| `compat_mode` | `napi-compat-mode/src/lib.zig` | compat-mode examples                                                                  |
| `example`     | `napi/src/lib.zig`             | shared example surface                                                                |
| `contracts`   | `napi/src/contracts.zig`       | end-to-end conversion, ownership and resource-lifecycle contracts                     |
| `conversion`  | `napi/src/conversion.zig`      | argument conversion, numeric bounds, rollback and return ownership                    |
| `classes`     | `napi/src/classes.zig`         | class wrapper and binary wrapper behaviour and finalization                           |
| `async_tasks` | `napi/src/async_tasks.zig`     | async ownership, AbortSignal, cancellation, promise settlement and TSFN queue cleanup |

The last four addons are built with a counting allocator so their specs can
assert that native allocations return to their baseline, on the failure paths
included.

## Native tests

```bash
cd node-test
npm run build:test   # zig build --summary all
npm run test:run     # ava --serial
```

These two commands run from `node-test/`; every other command in this document
runs from the repository root, so `cd ..` (or open a fresh shell) before
copying the WASI and benchmark commands below.

`npm run test:run` discovers `napi-compat-mode/__tests__/**/*.spec.js`,
`napi/__tests__/**/*.spec.js` and `wasm/*.spec.js`. The WASI lifecycle spec is
part of that run and is gated on the built artifacts: on a native-only run (no
`async_tasks` WASI artifact and `NAPI_RS_FORCE_WASI` unset) all 11 of its cases
are skipped, while with the artifacts present they run in child processes that
load the raw `.wasm` through `node:wasi` directly, not through the generated
loaders. Building both flavors enables all 11 cases on both flavors. Forced
WASI never skips: a missing artifact goes through the explicit missing-artifact
check and fails the run (the loader names the binding and the build command)
instead of falling back to a native binary.

## WASI tests

All commands in this section run from the repository root.

Build both flavors first; a build only regenerates the flavor it targets, and it
also regenerates the committed `.wasi.cjs`/`.wasip1.cjs` loaders, their browser
variants and worker files:

```bash
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1-threads -- --summary all
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1 -- --summary all
```

Run the matrix against one flavor at a time:

```bash
NAPI_RS_FORCE_WASI=error ZIG_NAPI_WASI_FLAVOR=wasi   pnpm --filter zig-napi-node-test run test:run
NAPI_RS_FORCE_WASI=error ZIG_NAPI_WASI_FLAVOR=wasip1 pnpm --filter zig-napi-node-test run test:run
```

Only the cases whose assertions rest on native-specific facilities — the
counting allocator's accounting, forced collection through `--expose-gc` and
similar native-only assumptions — are marked native-only and skipped under
`NAPI_RS_FORCE_WASI` (39 skips per flavor run). Tests that spawn child
processes still execute, and the lifecycle cases run their raw-runtime children
as described above, so the skips name what a WASI build cannot cover rather
than the whole child-process category.

The raw-runtime acceptance suites run against the built artifacts:

```bash
node --test --test-timeout=300000 node-test/wasm/abi.test.cjs node-test/wasm/concurrency.test.cjs
```

Both read `ZIG_NAPI_WASM_ARTIFACT_ROOT` (default `node-test/`). `abi.test.cjs`
additionally runs its allocation-failure case only when
`ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT` points at a small-memory build
(`-Dwasi-max-memory-pages=520`), and the concurrency suite is also run against
ReleaseSafe/ReleaseFast artifacts in CI through the same variable.

## Benchmarks

Both commands run from the repository root, like the WASI section:

```bash
node node-test/wasm/queue-benchmark.cjs --flavor=both   # event queue bounds/latency
node node-test/benchmarks/resource-memory.cjs           # memory retained per workload
```

`resource-memory.cjs` is a diagnostic: it spawns one fresh process per workload
and prints the native byte count, allocation count and RSS it observed. RSS
depends on the Node version, GC timing and platform, so it is reported for
inspection rather than asserted.
