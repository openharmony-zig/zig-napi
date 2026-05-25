# N-API Value Conversion Refactor Plan

## Background

Current conversion APIs such as `Napi.from_napi_value_auto(...)` return `T` directly and use `NapiError.last_error` as an out-of-band error channel. This can produce unsafe behavior: a failed conversion may still return a placeholder/default value, and callers must remember to check `last_error` before storing or cleaning up the converted value.

The immediate target is to align the exported-call behavior with napi-rs semantics:

- Convert JS arguments before calling native code.
- If conversion fails, throw a JS error and return immediately.
- Never store or clean up failed conversion results.
- Treat missing JS arguments as `undefined`, not uninitialized `napi_value`.

## Phase 1: Minimal `!T` Refactor

Goal: make failed conversion impossible to accidentally use by changing conversion helpers from `T` to `!T`, while keeping `NapiError.last_error` temporarily for detailed error payloads.

### Scope

- Change `Napi.from_napi_value_fast(env, raw, T) T` to `!T`.
- Change `Napi.from_napi_value_auto(env, raw, T) T` to `!T`.
- Change `Napi.from_napi_value(env, raw, T) T` to `!T`.
- Update all direct call sites under:
  - `src/napi/value/function.zig`
  - `src/napi/wrapper/class.zig`
  - `src/napi/value/array.zig`
  - `src/napi/value/object.zig`
- Update wrapper/value `from_napi_value` implementations that currently return `T` directly:
  - number
  - bool
  - string
  - bigint
  - array
  - object
  - buffer
  - arraybuffer
  - reference
  - abort signal if needed

### Required Behavior

- Function/class entrypoints use `try`/`catch` style flow instead of reading failed values.
- `initialized_params` / `initialized_args` are incremented only after conversion succeeds.
- Array/object recursive conversion frees already-created owned values if a later element/property conversion fails.
- Missing arguments continue to be normalized to JS `undefined`.

### Tests

- Existing `node-test/napi/__tests__/strict.spec.js` must stay green.
- Add focused tests for nested partial-conversion failure:
  - array with first element valid and second invalid
  - object with first field valid and second invalid
  - union variants with slice/string payloads
- Run:
  - `zig build --summary failures`
  - `zig build --summary failures` in `node-test`
  - `just test-node-matrix`
  - `git diff --check`

### Estimate

0.5 to 1 day.

## Phase 2: Structured Conversion Result

Goal: remove or sharply reduce `NapiError.last_error` by returning structured conversion errors, closer to napi-rs `Result<T, Error>`.

Possible Zig shape:

```zig
pub fn NapiResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: napi.Error,
    };
}
```

Alternative: keep Zig `!T` for control flow and add a scoped error payload object passed through conversion helpers. This avoids threadlocal state but is more invasive at call sites.

### Scope

- Replace `last_error`-based conversion failure propagation.
- Update async/worker/class/function error handling to consume structured errors.
- Decide public API breakage for helpers like:
  - `Object.Get(...)`
  - `Object.GetNamed(...)`
  - `Array.Get(...)`
- Update docs and examples if these APIs become fallible.

### Tests

- Keep all Phase 1 tests.
- Add class constructor/method/setter invalid-argument tests.
- Add worker/async conversion error propagation tests if exposed by current API surface.
- Run Node matrix across Node 12/14/16/18/20/22 on Linux/macOS/Windows in CI.

### Estimate

2 to 4 days.

## Recommended Order

1. Land Phase 1 first to eliminate unsafe failed-value usage.
2. Expand strict invalid-input tests around array/object/class conversion.
3. Re-run CI matrix and watch for platform-specific N-API behavior.
4. Plan Phase 2 only after Phase 1 is stable, because it may require public API changes.

## Risks

- `Object.Get` / `Array.Get` becoming fallible may be a source-compatible breaking change.
- Array/object conversion must carefully deinit partially converted owned values.
- Some wrappers currently assume N-API conversion calls cannot fail; those assumptions need explicit handling.
- Keeping `last_error` during Phase 1 means detailed error propagation is still threadlocal, but failed values will no longer be used.
