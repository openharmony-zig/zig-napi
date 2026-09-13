"use strict";

/**
 * WASI flavor model and loader/worker generators for the zig-napi CLI.
 *
 * The generated files are adaptations of napi-rs, which is MIT licensed:
 *
 *   napi-rs (https://github.com/napi-rs/napi-rs)
 *   Copyright (c) 2020-present LongYinan
 *   Adapted from `cli/src/api/templates/load-wasi-template.ts` and
 *   `cli/src/api/templates/wasi-worker-template.ts` at
 *   39bd1205e480a453a2da2601a760bde5a71ed016 (the `@napi-rs/cli` 3.9.1
 *   sources), and from the `@napi-rs/wasm-runtime` 1.2.4 plugin contract.
 *   Licensed under the MIT License; see this repository's LICENSE for the
 *   full text and https://github.com/napi-rs/napi-rs/blob/main/LICENSE for
 *   the upstream notice.
 *
 * The adapted sources stay local because those modules are not exported from
 * the `@napi-rs/cli` public entry point. They are pinned to the same runtime
 * contract: emnapi 2.x contexts, the `@napi-rs/wasm-runtime` plugins, and the
 * `napi_prepare_wasm_env_cleanup` / `napi_wasm_env_cleanup_pending` teardown
 * handshake. Local differences from upstream are marked in comments at the
 * point of change (validated worker pools, process-wide exit listener
 * registry, `zig-out/node` artifact fallback, scoped package names, no private
 * Node.js symbol patching).
 */

/** wasm page size in bytes, the unit `WebAssembly.Memory` is configured in. */
const WASM_PAGE_SIZE = 65536;
/** 4 GiB, the maximum a 32 bit wasm memory can address. */
const MAX_WASM_PAGES = 65536;
/**
 * Floor for `napi.wasm.initialMemory`. Zig's wasi linker script reserves a
 * 16 MiB stack inside the linear memory, and the linked image adds its data on
 * top, so anything below that cannot be satisfied by the module the loader
 * instantiates.
 */
const MIN_WASM_PAGES = 256;
const DEFAULT_INITIAL_MEMORY = 4000;
const DEFAULT_MAXIMUM_MEMORY = 65536;
/** deferred (workerd) loader default: 64 MiB, headroom under workerd's isolate limit. */
const DEFAULT_DEFERRED_INITIAL_MEMORY = 1024;

class WasiConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = "WasiConfigError";
  }
}

/**
 * `wasm32-wasi` is the historical spelling of the threaded flavor, so it must
 * never be treated as threadless just because its name lacks the suffix.
 */
const WASI_FLAVORS = [
  {
    canonicalTriple: "wasm32-wasip1-threads",
    platformArchABI: "wasm32-wasi",
    loaderSuffix: "wasi",
    threads: true,
  },
  {
    canonicalTriple: "wasm32-wasip1",
    platformArchABI: "wasm32-wasip1",
    loaderSuffix: "wasip1",
    threads: false,
  },
];

const WASI_TARGET_FLAVORS = new Map([
  ["wasm32-wasi", WASI_FLAVORS[0]],
  ["wasm32-wasi-preview1-threads", WASI_FLAVORS[0]],
  ["wasm32-wasip1-threads", WASI_FLAVORS[0]],
  ["wasm32-wasip1", WASI_FLAVORS[1]],
]);

function getWasiFlavor(target) {
  if (typeof target !== "string") return undefined;
  return WASI_TARGET_FLAVORS.get(target.trim());
}

function isWasiTargetName(target) {
  return getWasiFlavor(target) !== undefined;
}

function isWasiThreadsTargetName(target) {
  return getWasiFlavor(target)?.threads === true;
}

/** Canonical triple of a WASI spelling, or the input when it is not WASI. */
function normalizeWasiTargetName(target) {
  return getWasiFlavor(target)?.canonicalTriple ?? target;
}

/**
 * Distinct flavors of the configured targets, threaded first: that is the
 * order `@napi-rs/cli` uses for its own WASI fallback chain, and the threaded
 * flavor is the one every historical project is built with.
 */
function collectWasiFlavors(targets) {
  const flavors = [];
  const seen = new Set();
  for (const target of targets) {
    const flavor = getWasiFlavor(target);
    if (!flavor || seen.has(flavor.platformArchABI)) continue;
    seen.add(flavor.platformArchABI);
    flavors.push(flavor);
  }
  return flavors.sort((left, right) => Number(right.threads) - Number(left.threads));
}

function wasiLoaderSuffix(platformArchABI) {
  return platformArchABI.replace(/^wasm32-/, "");
}

/** `<scope>/<name>` -> `<scope>/<name>-<platformArchABI>`, `<name>` -> `<name>-<platformArchABI>`. */
function optionalPackageName(packageName, platformArchABI) {
  const slash = packageName.startsWith("@") ? packageName.indexOf("/") : -1;
  if (slash === -1) {
    return `${packageName}-${platformArchABI}`;
  }
  return `${packageName.slice(0, slash + 1)}${packageName.slice(slash + 1)}-${platformArchABI}`;
}

/** Every file the CLI writes for one flavor, relative to the output directory. */
function wasiFlavorFileNames(binaryName, flavor) {
  const suffix = flavor.loaderSuffix;
  const fileNames = [
    `${binaryName}.${suffix}.cjs`,
    `${binaryName}.${suffix}.d.cts`,
    `${binaryName}.${suffix}-browser.js`,
  ];
  if (flavor.threads) {
    fileNames.push("wasi-worker.mjs", "wasi-worker-browser.mjs");
  } else {
    fileNames.push(`${binaryName}.${suffix}-deferred.js`, `${binaryName}.${suffix}-deferred.d.ts`);
  }
  return fileNames;
}

/**
 * Files owned by the CLI for any flavor. Used to delete loaders of flavors the
 * project no longer configures, without ever touching an unmanaged file.
 */
function managedWasiFileNames(binaryName) {
  const fileNames = new Set(["browser.js", "wasi-worker.mjs", "wasi-worker-browser.mjs"]);
  for (const flavor of WASI_FLAVORS) {
    for (const fileName of wasiFlavorFileNames(binaryName, flavor)) {
      fileNames.add(fileName);
    }
  }
  return fileNames;
}

/**
 * Managed files paired with the flavor that owns them, so a build of one flavor
 * can delete the other flavor's files only when that flavor is no longer
 * configured.
 */
function managedWasiFilesByFlavor(binaryName) {
  const entries = [];
  for (const flavor of WASI_FLAVORS) {
    for (const fileName of wasiFlavorFileNames(binaryName, flavor)) {
      entries.push({ flavor, fileName });
    }
  }
  return entries;
}

function assertPageCount(value, field, fallback) {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new WasiConfigError(`napi.wasm.${field} must be an integer number of wasm pages`);
  }
  if (value < 1 || value > MAX_WASM_PAGES) {
    throw new WasiConfigError(
      `napi.wasm.${field} must be between 1 and ${MAX_WASM_PAGES} pages (${MAX_WASM_PAGES * WASM_PAGE_SIZE} bytes)`,
    );
  }
  if (value < MIN_WASM_PAGES) {
    throw new WasiConfigError(
      `napi.wasm.${field} is ${value} pages (${value * WASM_PAGE_SIZE} bytes); a WASI addon needs at least ${MIN_WASM_PAGES} pages (${MIN_WASM_PAGES * WASM_PAGE_SIZE} bytes) because the Zig linker reserves a 16 MiB stack inside the linear memory`,
    );
  }
  return value;
}

function assertOptionalBoolean(value, field) {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value !== "boolean") {
    throw new WasiConfigError(`napi.wasm.browser.${field} must be a boolean`);
  }
  return value;
}

/**
 * Validated `napi.wasm` configuration. The values are what both the generated
 * loaders and the linker-memory build flags are derived from, so an invalid
 * value must fail the build instead of producing a loader that cannot
 * instantiate the module.
 */
function resolveWasmConfig(config) {
  const wasm = config?.wasm ?? {};
  if (wasm === null || typeof wasm !== "object" || Array.isArray(wasm)) {
    throw new WasiConfigError("napi.wasm must be an object");
  }
  const initialMemory = assertPageCount(
    wasm.initialMemory,
    "initialMemory",
    DEFAULT_INITIAL_MEMORY,
  );
  const maximumMemory = assertPageCount(
    wasm.maximumMemory,
    "maximumMemory",
    DEFAULT_MAXIMUM_MEMORY,
  );
  if (initialMemory > maximumMemory) {
    throw new WasiConfigError(
      `napi.wasm.initialMemory (${initialMemory}) must not exceed napi.wasm.maximumMemory (${maximumMemory})`,
    );
  }
  if (initialMemory === maximumMemory) {
    // A wasm memory may always grow up to its maximum, but this build's
    // allocator cannot: wasi-libc's sbrk and the Zig BrkAllocator extend the
    // heap by growing linear memory beyond its current size, so an environment
    // with no headroom traps on the first allocation past the initial size
    // instead of failing a grow. Leave room explicitly.
    throw new WasiConfigError(
      `napi.wasm.initialMemory and napi.wasm.maximumMemory are both ${initialMemory} pages, which leaves no room to grow; the Zig/wasi-libc allocator grows linear memory on every allocation past the initial size, so set maximumMemory above initialMemory (for example ${initialMemory + MIN_WASM_PAGES})`,
    );
  }
  const browser = wasm.browser ?? {};
  if (browser === null || typeof browser !== "object" || Array.isArray(browser)) {
    throw new WasiConfigError("napi.wasm.browser must be an object");
  }
  return {
    initialMemory,
    maximumMemory,
    browser: {
      fs: assertOptionalBoolean(browser.fs, "fs"),
      asyncInit: assertOptionalBoolean(browser.asyncInit, "asyncInit"),
      buffer: assertOptionalBoolean(browser.buffer, "buffer"),
      errorEvent: assertOptionalBoolean(browser.errorEvent, "errorEvent"),
    },
  };
}

/**
 * Turns `napi.wasm.initialMemory` / `maximumMemory` (pages) into the wasm-ld
 * limits the build must declare so the linked module accepts the `Memory` the
 * loader allocates. Returns an empty array when the project uses the defaults,
 * which keeps builds without an explicit configuration byte-for-byte
 * unchanged.
 *
 * Option names and units are owned by the zig-napi build helper
 * (`src/build/napi-build.zig`, `wasi-initial-memory-pages` /
 * `wasi-max-memory-pages`), which declares them once per build; the CLI never
 * probes the build script for them.
 */
function wasiMemoryBuildArgs(config) {
  const wasm = config?.wasm ?? {};
  const args = [];
  if (wasm.initialMemory !== undefined && wasm.initialMemory !== null) {
    args.push(`-Dwasi-initial-memory-pages=${resolveWasmConfig(config).initialMemory}`);
  }
  if (wasm.maximumMemory !== undefined && wasm.maximumMemory !== null) {
    args.push(`-Dwasi-max-memory-pages=${resolveWasmConfig(config).maximumMemory}`);
  }
  return args;
}

const WASI_DISPOSE_SYMBOL = "napi.rs.wasi.dispose";
const WASI_ROLLBACK_REGISTRY_SYMBOL = "napi.rs.wasi.rollback.registry.v1";

/**
 * Shared teardown machinery.
 *
 * `napi_prepare_wasm_env_cleanup()` only *queues* the settlements of the tasks
 * it cancels, and `Context.destroy()` runs the threadsafe function cleanup hook
 * that drains that queue with a null env and discards whatever is still in it.
 * Destroying the context without yielding first therefore strands exactly the
 * promises the barrier exists to settle, so disposal waits for
 * `napi_wasm_env_cleanup_pending()` to reach zero on real event-loop turns.
 */
const EMNAPI_CONTEXT_LIFECYCLE = `
const __wasiDisposeSymbol = Symbol.for("${WASI_DISPOSE_SYMBOL}");
const __wasiWorkers = new Set();
let __napiInstance;
let __emnapiContextDestroyed = false;
let __emnapiContextDestroyPromise;
let __emnapiWasmEnvCleanupPrepared = false;
let __emnapiWasmEnvCleanupRan = false;
let __emnapiWasmEnvCleanupDrained = false;
let __emnapiWasmEnvCleanupDrainPromise;
let __wasiDisposed = false;
let __wasiDisposePromise;
let __completeWasiDisposal = function () {};
// Overridden by loader flavors that have a last-resort reclaim for a rollback
// that stopped short of destroying the context.
let __retainWasiRollbackForRetry = function () {};

function __isThenable(value) {
  return (
    value !== null &&
    (typeof value === "object" || typeof value === "function") &&
    typeof value.then === "function"
  );
}

function __createCleanupError(errors, message) {
  if (errors.length === 1) {
    return errors[0];
  }
  const __AggregateError = globalThis.AggregateError;
  if (typeof __AggregateError === "function") {
    return new __AggregateError(errors, message);
  }
  const error = new Error(message);
  error.errors = errors;
  return error;
}

function __attachCleanupErrors(error, cleanupErrors) {
  if (cleanupErrors.length === 0) {
    return error;
  }
  const cleanupError = __createCleanupError(cleanupErrors, "WASI binding cleanup failed");
  try {
    if (error && (typeof error === "object" || typeof error === "function")) {
      if (error.cause === undefined) {
        error.cause = cleanupError;
        if (error.cause === cleanupError) {
          return error;
        }
      }
      if (Array.isArray(error.cleanupErrors)) {
        error.cleanupErrors.push(cleanupError);
        return error;
      }
      const attachedCleanupErrors = [cleanupError];
      error.cleanupErrors = attachedCleanupErrors;
      if (error.cleanupErrors === attachedCleanupErrors) {
        return error;
      }
    }
  } catch {}
  const aggregate = __createCleanupError(
    [error, cleanupError],
    "WASI binding initialization and cleanup failed",
  );
  try {
    aggregate.cause = error;
  } catch {}
  return aggregate;
}

function __prepareWasmEnvCleanup() {
  if (__emnapiWasmEnvCleanupPrepared) {
    return;
  }
  const prepare = __napiInstance?.exports?.napi_prepare_wasm_env_cleanup;
  if (typeof prepare === "function") {
    prepare();
    __emnapiWasmEnvCleanupRan = true;
  }
  __emnapiWasmEnvCleanupPrepared = true;
}

// Mirror the primitive @emnapi/core schedules its threadsafe-function dispatch
// on, so the drain turns below interleave with that dispatch instead of racing
// ahead of it on a faster queue.
const __scheduleMacrotask = (function () {
  if (typeof setImmediate === "function") {
    return function (callback) {
      setImmediate(callback);
    };
  }
  const __MessageChannel = globalThis.MessageChannel;
  if (typeof __MessageChannel === "function") {
    return function (callback) {
      const channel = new __MessageChannel();
      channel.port1.onmessage = function () {
        channel.port1.onmessage = null;
        try {
          channel.port1.close();
        } catch {}
        try {
          channel.port2.close();
        } catch {}
        callback();
      };
      channel.port2.postMessage(null);
    };
  }
  return function (callback) {
    setTimeout(callback, 0);
  };
})();

// Turns to wait for while the addon still reports queued settlements. Reaching
// zero is the only success; a counter still nonzero at this bound rejects the
// disposal as retryable (ERR_NAPI_WASI_CLEANUP_PENDING) instead of destroying
// the context over a still-queued settlement.
const __WASM_ENV_CLEANUP_DRAIN_TURNS = 128;
// Without napi_wasm_env_cleanup_pending the queue is not observable. Fall back
// to the number of turns @emnapi/core needs to coalesce and dispatch a call
// made on this thread (two), plus a margin.
const __WASM_ENV_CLEANUP_BLIND_DRAIN_TURNS = 4;

function __drainWasmEnvCleanup() {
  if (__emnapiWasmEnvCleanupDrained || !__emnapiWasmEnvCleanupRan) {
    return;
  }
  if (__emnapiWasmEnvCleanupDrainPromise) {
    return __emnapiWasmEnvCleanupDrainPromise;
  }
  const pending = __napiInstance?.exports?.napi_wasm_env_cleanup_pending;
  const observable = typeof pending === "function";
  if (observable) {
    let queued;
    try {
      queued = pending();
    } catch {
      __emnapiWasmEnvCleanupDrained = true;
      return;
    }
    if (!queued) {
      __emnapiWasmEnvCleanupDrained = true;
      return;
    }
  }
  const limit = observable ? __WASM_ENV_CLEANUP_DRAIN_TURNS : __WASM_ENV_CLEANUP_BLIND_DRAIN_TURNS;
  const drainPromise = (async () => {
    let queued = 0;
    for (let turn = 0; turn < limit; turn++) {
      await new Promise((resolve) => {
        __scheduleMacrotask(resolve);
      });
      if (!observable) {
        continue;
      }
      try {
        queued = pending();
      } catch {
        return;
      }
      if (!queued) {
        return;
      }
    }
    if (!observable) {
      // Blind wait: without napi_wasm_env_cleanup_pending the bound IS the
      // contract - there is nothing to consult, so finishing the turns is
      // finishing the drain.
      return;
    }
    // Claiming success here would be indistinguishable from the stranding this
    // drain exists to prevent: disposal would go on to destroy the context,
    // whose cleanup hook discards the still-queued settlement with a null env.
    // Reject as a retryable cleanup failure instead - the drained flag stays
    // unset, nothing is destroyed, and a later dispose() drains again by which
    // time the queue has usually been delivered.
    const drainError = new Error(
      "the wasm environment still reports " +
        queued +
        " queued settlement(s) after " +
        limit +
        " event-loop turns; the context was not destroyed - retry dispose() to wait for the queue again",
    );
    drainError.code = "ERR_NAPI_WASI_CLEANUP_PENDING";
    throw drainError;
  })().then(
    (value) => {
      // Set only when the wait actually finished AND the queue was seen empty
      // (or is unobservable): a drain that timed out rejects above and must
      // stay repeatable.
      __emnapiWasmEnvCleanupDrained = true;
      __emnapiWasmEnvCleanupDrainPromise = undefined;
      return value;
    },
    (error) => {
      __emnapiWasmEnvCleanupDrainPromise = undefined;
      throw error;
    },
  );
  __emnapiWasmEnvCleanupDrainPromise = drainPromise;
  return drainPromise;
}

function __destroyEmnapiContext() {
  if (__emnapiContextDestroyed || __emnapiContext === undefined) {
    __emnapiContextDestroyed = true;
    return;
  }
  if (__emnapiContextDestroyPromise) {
    return __emnapiContextDestroyPromise;
  }
  // Context.destroy() disables JS before cleanup hooks run, so settle what the
  // barrier queued while this environment can still call JavaScript.
  __prepareWasmEnvCleanup();
  const result = __emnapiContext.destroy();
  if (!__isThenable(result)) {
    __emnapiContextDestroyed = true;
    return;
  }
  const destroyPromise = Promise.resolve(result).then(
    (value) => {
      __emnapiContextDestroyed = true;
      return value;
    },
    (error) => {
      __emnapiContextDestroyPromise = undefined;
      throw error;
    },
  );
  __emnapiContextDestroyPromise = destroyPromise;
  return destroyPromise;
}

function __terminateWasiWorkers() {
  const cleanupErrors = [];
  const pending = [];
  for (const worker of __wasiWorkers) {
    let result;
    try {
      result = worker.terminate();
    } catch (error) {
      cleanupErrors.push(error);
      continue;
    }
    if (__isThenable(result)) {
      pending.push(
        Promise.resolve(result).then(
          () => {
            __wasiWorkers.delete(worker);
          },
          (error) => {
            cleanupErrors.push(error);
          },
        ),
      );
    } else {
      __wasiWorkers.delete(worker);
    }
  }
  const finish = () => {
    if (cleanupErrors.length > 0) {
      throw __createCleanupError(cleanupErrors, "Failed to terminate WASI workers");
    }
  };
  return pending.length > 0 ? Promise.all(pending).then(finish) : finish();
}

function __finishWasiDisposal() {
  const workerResult = __terminateWasiWorkers();
  if (__isThenable(workerResult)) {
    return Promise.resolve(workerResult).then(__completeWasiDisposal);
  }
  return __completeWasiDisposal();
}

function __continueWasiDisposal() {
  const destroyResult = __destroyEmnapiContext();
  if (__isThenable(destroyResult)) {
    return Promise.resolve(destroyResult).then(__finishWasiDisposal);
  }
  return __finishWasiDisposal();
}

function __startWasiDisposal() {
  // Run the pre-teardown barrier, let the settlements it queued reach
  // JavaScript, and only then destroy the environment. Doing these two back to
  // back is what strands them.
  __prepareWasmEnvCleanup();
  const drainResult = __drainWasmEnvCleanup();
  if (__isThenable(drainResult)) {
    return Promise.resolve(drainResult).then(__continueWasiDisposal);
  }
  return __continueWasiDisposal();
}

function __disposeWasiBinding() {
  if (__wasiDisposePromise) {
    return __wasiDisposePromise;
  }
  if (__wasiDisposed) {
    return Promise.resolve();
  }
  let resolveDispose;
  let rejectDispose;
  const disposePromise = new Promise((resolve, reject) => {
    resolveDispose = resolve;
    rejectDispose = reject;
  });
  __wasiDisposePromise = disposePromise;
  let result;
  try {
    result = __startWasiDisposal();
  } catch (error) {
    __wasiDisposePromise = undefined;
    rejectDispose(error);
    return disposePromise;
  }
  Promise.resolve(result).then(
    (value) => {
      __wasiDisposed = true;
      resolveDispose(value);
    },
    (error) => {
      __wasiDisposePromise = undefined;
      rejectDispose(error);
    },
  );
  return disposePromise;
}

/**
 * Publishes the disposal hook on the binding exports. Access it with
 * binding[Symbol.for("${WASI_DISPOSE_SYMBOL}")]().
 */
function __publishWasiDispose(exports) {
  Object.defineProperty(exports, __wasiDisposeSymbol, {
    configurable: false,
    enumerable: false,
    value: __disposeWasiBinding,
    writable: false,
  });
}

function __finishWasiInitializationRollback(cleanupErrors) {
  let workerResult;
  try {
    workerResult = __terminateWasiWorkers();
  } catch (cleanupError) {
    cleanupErrors.push(cleanupError);
    return cleanupErrors;
  }
  if (__isThenable(workerResult)) {
    return Promise.resolve(workerResult)
      .catch((cleanupError) => {
        cleanupErrors.push(cleanupError);
      })
      .then(() => cleanupErrors);
  }
  return cleanupErrors;
}

function __destroyContextForWasiRollback(cleanupErrors) {
  let destroyResult;
  try {
    destroyResult = __destroyEmnapiContext();
  } catch (cleanupError) {
    cleanupErrors.push(cleanupError);
    return __finishWasiInitializationRollback(cleanupErrors);
  }
  if (__isThenable(destroyResult)) {
    return Promise.resolve(destroyResult)
      .catch((cleanupError) => {
        cleanupErrors.push(cleanupError);
      })
      .then(() => __finishWasiInitializationRollback(cleanupErrors));
  }
  return __finishWasiInitializationRollback(cleanupErrors);
}

function __retainFailedWasiRollback(cleanupErrors) {
  try {
    __retainWasiRollbackForRetry();
  } catch (cleanupError) {
    cleanupErrors.push(cleanupError);
  }
  return cleanupErrors;
}

/**
 * Initialization can fail after registration has already run, and registration
 * runs with a live environment: a module-init hook can start async work and
 * then return an error, and the promise it created may already have escaped
 * into JavaScript. The barrier cancels that work and queues the settlement, so
 * this path needs the same drain the ordinary disposal does.
 *
 * A barrier or drain that did not finish stops the rollback short of
 * destroying, exactly like dispose() does: destroying would run the cleanup
 * hook that discards the queued settlement with a null env, hanging a promise
 * that nothing could ever settle. The retained context is reclaimed by the
 * flavor's process teardown and can be retried.
 */
function __rollbackWasiInitialization() {
  const cleanupErrors = [];
  let drainResult;
  let settlementsUnreached = false;
  try {
    __prepareWasmEnvCleanup();
    drainResult = __drainWasmEnvCleanup();
  } catch (cleanupError) {
    cleanupErrors.push(cleanupError);
    settlementsUnreached = true;
  }
  if (__isThenable(drainResult)) {
    return Promise.resolve(drainResult).then(
      () => __destroyContextForWasiRollback(cleanupErrors),
      (cleanupError) => {
        cleanupErrors.push(cleanupError);
        return __retainFailedWasiRollback(cleanupErrors);
      },
    );
  }
  if (settlementsUnreached) {
    return __retainFailedWasiRollback(cleanupErrors);
  }
  return __destroyContextForWasiRollback(cleanupErrors);
}
`;

/**
 * Captures the `beforeExit` auto-destroy listener emnapi 2.x registers from the
 * `Context` constructor. `suppressDestroy()` only neutralizes its callback, it
 * does not remove the listener, and a loader must stay side-effect free on the
 * process it is loaded into.
 */
const CAPTURE_EMNAPI_AUTO_DESTROY_LISTENER = (processExpression) => `
function __captureEmnapiAutoDestroyListener() {
  const __process = ${processExpression};
  if (
    !__process ||
    typeof __process.prependListener !== "function" ||
    typeof __process.removeListener !== "function"
  ) {
    return;
  }
  let __autoDestroyListener;
  const __captureListener = (__event, __listener) => {
    if (__event === "beforeExit" && __autoDestroyListener === undefined) {
      __autoDestroyListener = __listener;
    }
  };
  try {
    // Run before existing newListener hooks so a hook that registers its own
    // beforeExit listener cannot be mistaken for emnapi's registration.
    __process.prependListener("newListener", __captureListener);
  } catch {
    return;
  }
  return () => {
    try {
      __process.removeListener("newListener", __captureListener);
    } catch {}
    if (__autoDestroyListener !== undefined) {
      try {
        __process.removeListener("beforeExit", __autoDestroyListener);
      } catch {}
    }
  };
}
`;

const NODE_WORKER_EXEC_ARGV_HELPERS = `
function __getWasiWorkerExecArgv() {
  const __workerExecArgv = [];
  for (let index = 0; index < process.execArgv.length; index += 1) {
    const arg = process.execArgv[index];
    if (
      arg === "--input-type" ||
      arg === "--eval" ||
      arg === "-e" ||
      arg === "--print" ||
      arg === "-p"
    ) {
      index += 1;
      continue;
    }
    if (arg.startsWith("--input-type=") || arg.startsWith("--eval=") || arg.startsWith("--print=")) {
      continue;
    }
    __workerExecArgv.push(arg);
  }
  return __workerExecArgv;
}

function __isInvalidWasiWorkerExecArgv(errorMessage, argument) {
  const equalsIndex = argument.indexOf("=");
  const argumentName = equalsIndex === -1 ? argument : argument.slice(0, equalsIndex);
  return (
    errorMessage.includes(": " + argumentName + ",") ||
    errorMessage.includes(": " + argumentName + "=") ||
    errorMessage.endsWith(": " + argumentName) ||
    errorMessage.includes(", " + argumentName + ",") ||
    errorMessage.includes(", " + argumentName + "=") ||
    errorMessage.endsWith(", " + argumentName)
  );
}

function __removeInvalidWasiWorkerExecArgv(execArgv, error) {
  if (typeof error.message !== "string") {
    return;
  }
  const __workerExecArgv = [];
  let removed = false;
  for (let index = 0; index < execArgv.length; index += 1) {
    const arg = execArgv[index];
    if (arg.startsWith("-") && __isInvalidWasiWorkerExecArgv(error.message, arg)) {
      removed = true;
      if (!arg.includes("=") && index + 1 < execArgv.length && !execArgv[index + 1].startsWith("-")) {
        index += 1;
      }
      continue;
    }
    __workerExecArgv.push(arg);
  }
  return removed ? __workerExecArgv : undefined;
}

function __createWasiWorker(filename) {
  let __workerExecArgv = __getWasiWorkerExecArgv();
  for (;;) {
    try {
      return new Worker(filename, {
        env: process.env,
        execArgv: __workerExecArgv,
        workerData: { hostRoot: __hostRoot, rootDir: __rootDir },
      });
    } catch (error) {
      if (!error || error.code !== "ERR_WORKER_INVALID_EXEC_ARGV") {
        throw error;
      }
      const nextWorkerExecArgv = __removeInvalidWasiWorkerExecArgv(__workerExecArgv, error);
      if (!nextWorkerExecArgv) {
        throw error;
      }
      __workerExecArgv = nextWorkerExecArgv;
    }
  }
}
`;

function memoryDeclaration({ threads, initialMemory, maximumMemory, name }) {
  return `const ${name} = new WebAssembly.Memory({
  initial: ${initialMemory},
  maximum: ${maximumMemory},${threads ? "\n  shared: true," : ""}
});
`;
}

/**
 * Worker pool sizes come from the host (`NAPI_RS_ASYNC_WORK_POOL_SIZE`,
 * `UV_THREADPOOL_SIZE`, `navigator.hardwareConcurrency`). A non-finite,
 * fractional, non-positive or absurd value would spawn an unbounded number of
 * workers, so an invalid value falls back to the flavor's default instead of
 * being used as-is.
 *
 * The bound is 64 for both hosts, not the `1024` a large `UV_THREADPOOL_SIZE`
 * could ask for: every pooled worker instantiates the addon and reserves its
 * own linear memory (hundreds of MiB with the default 4000 pages), so a
 * four-digit pool exhausts the address space and the process before it is ever
 * useful. Upstream leaves the value unbounded in Node; the browser already
 * derives its pool from `hardwareConcurrency`, and this keeps both hosts in the
 * same validated range.
 */
function workerPoolValidationHelpers({ maxPoolSize }) {
  return `const __DEFAULT_ASYNC_WORK_POOL_SIZE = 4;
const __MAX_ASYNC_WORK_POOL_SIZE = ${maxPoolSize};

function __normalizeWorkerCount(value, defaultValue, maxValue) {
  if (!Number.isFinite(value) || !Number.isInteger(value) || value <= 0 || value > maxValue) {
    return defaultValue;
  }
  return value;
}

function __warnInvalidWorkerCount(value, fallback) {
  const message =
    "zig-napi: ignoring invalid worker pool size " + value + "; using " + fallback;
  if (typeof process === "object" && process !== null && typeof process.emitWarning === "function") {
    process.emitWarning(message);
    return;
  }
  globalThis.console?.warn?.(message);
}

`;
}

/**
 * Appends an actionable hint when instantiation fails on the imported memory.
 * The loader allocates the memory the module imports, so a limit mismatch
 * between `napi.wasm` and the linked module surfaces here as an opaque
 * LinkError/RangeError.
 */
function instantiationMemoryHint({ threads, initialMemory, maximumMemory }) {
  const description =
    "the loader allocates WebAssembly.Memory(initial: " +
    initialMemory +
    " pages, maximum: " +
    maximumMemory +
    (threads ? " pages, shared: true)" : " pages)") +
    "; the linked wasm must declare the same limits (zig-napi passes -Dwasi-initial-memory-pages / -Dwasi-max-memory-pages from napi.wasm.initialMemory / maximumMemory)";
  return `
function __annotateWasiInstantiationError(error) {
  if (error && typeof error.message === "string" && /memory|linkerror/i.test(error.message)) {
    error.message += "\\n[zig-napi] " + ${JSON.stringify(description)};
  }
  return error;
}
`;
}

/**
 * Node.js CommonJS loader (`<binary>.<suffix>.cjs`).
 *
 * Threaded flavors instantiate with the emnapi worker pool (`reuseWorker`) and
 * a shared memory; non-threaded flavors instantiate with no workers and an
 * unshared memory, and rely on the emnapi plugins for async work and
 * thread-safe functions (their archives ship no C implementations).
 */
function createWasiNodeBinding(options) {
  const {
    wasmFileName,
    packageWasmFileName = wasmFileName,
    packageName,
    platformArchABI,
    threads,
    initialMemory = DEFAULT_INITIAL_MEMORY,
    maximumMemory = DEFAULT_MAXIMUM_MEMORY,
  } = options;
  const wasiPackageName = optionalPackageName(packageName, platformArchABI);
  const memoryName = threads ? "__sharedMemory" : "__wasmMemory";
  const workerImports = threads ? `const { Worker } = require("node:worker_threads");\n` : "";
  const workerRuntimeImport = threads
    ? `  createOnMessage: __wasmCreateOnMessageForFsProxy,\n`
    : "";
  const asyncWorkOptions = threads
    ? `    asyncWorkPoolSize: __asyncWorkPoolSize,
    reuseWorker: true,
`
    : `    asyncWorkPoolSize: 0,
`;
  const workerOption = threads
    ? `    onCreateWorker() {
      const worker = __createWasiWorker(__nodePath.join(__dirname, "wasi-worker.mjs"));
      __wasiWorkers.add(worker);
      worker.onmessage = ({ data }) => {
        __wasmCreateOnMessageForFsProxy(__nodeFs)(data);
      };
      // Pooled workers live as long as the addon does, and Rust threads are
      // never joined, so a referenced worker would keep the Node.js main
      // thread alive forever. unref() is the documented way to make a worker
      // non-blocking for process exit; pending async work still keeps the loop
      // alive through emnapi's own waiting-request counter, and worker message
      // delivery is unaffected.
      worker.unref();
      return worker;
    },
`
    : "";
  const asyncWorkPoolSizeBinding = threads
    ? `${workerPoolValidationHelpers({ maxPoolSize: 64 })}const __asyncWorkPoolSize = (function () {
  const configured = Number(
    process.env.NAPI_RS_ASYNC_WORK_POOL_SIZE ?? process.env.UV_THREADPOOL_SIZE,
  );
  // Unset (NaN) and an explicit 0 both mean "use the default"; anything else
  // has to be a finite, positive, bounded integer.
  if (Number.isNaN(configured) || configured === 0) {
    return __DEFAULT_ASYNC_WORK_POOL_SIZE;
  }
  const normalized = __normalizeWorkerCount(
    configured,
    __DEFAULT_ASYNC_WORK_POOL_SIZE,
    __MAX_ASYNC_WORK_POOL_SIZE,
  );
  if (normalized !== configured) {
    __warnInvalidWorkerCount(configured, normalized);
  }
  return normalized;
})();

`
    : "";

  return `/* eslint-disable */
/* auto-generated by zig-napi */

const __nodeFs = require("node:fs");
const __nodePath = require("node:path");
const { WASI: __nodeWASI } = require("node:wasi");
${workerImports}
const {
  emnapiAsyncWorkPlugin: __emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin: __emnapiTSFNPlugin,
${workerRuntimeImport}  instantiateNapiModuleSync: __emnapiInstantiateNapiModuleSync,
} = require("@napi-rs/wasm-runtime");
const { createContext: __emnapiCreateContext } = require("@emnapi/runtime");
${threads ? NODE_WORKER_EXEC_ARGV_HELPERS : ""}
const __cwd = process.cwd();
const __rootDir = __nodePath.parse(__cwd).root;
// Android has no writable filesystem root, so the preopened root is the cwd.
const __hostRoot = process.platform === "android" ? __cwd : __rootDir;

const __wasi = new __nodeWASI({
  version: "preview1",
  env: process.env,
  preopens: {
    [__rootDir]: __hostRoot,
    [__hostRoot]: __hostRoot,
  },
});

${memoryDeclaration({ threads, initialMemory, maximumMemory, name: memoryName })}${asyncWorkPoolSizeBinding}const __wasmCandidates = [
  __nodePath.join(__dirname, "${wasmFileName}.debug.wasm"),
  __nodePath.join(__dirname, "${wasmFileName}.wasm"),
  __nodePath.join(__dirname, "zig-out", "node", "${wasmFileName}.debug.wasm"),
  __nodePath.join(__dirname, "zig-out", "node", "${wasmFileName}.wasm"),
];

// The packaged artifact lives in the optional <package>-<platformArchABI>
// package. Its entry point may sit in a subdirectory, so the artifact is
// searched from the entry directory up to the package root before falling back
// to resolving the artifact as a subpath (packages without an entry point).
function __resolvePackagedWasmPath() {
  const __wasmName = "${packageWasmFileName}.wasm";
  try {
    const __entry = require.resolve("${wasiPackageName}");
    let __directory = __nodePath.dirname(__entry);
    for (;;) {
      const __candidate = __nodePath.join(__directory, __wasmName);
      if (__nodeFs.existsSync(__candidate)) {
        return __candidate;
      }
      const __parent = __nodePath.dirname(__directory);
      if (__parent === __directory) {
        break;
      }
      __directory = __parent;
    }
  } catch {}
  try {
    return require.resolve("${wasiPackageName}/${packageWasmFileName}.wasm");
  } catch {}
  return undefined;
}

let __wasmFilePath = __wasmCandidates.find((candidate) => __nodeFs.existsSync(candidate));

if (!__wasmFilePath) {
  __wasmFilePath = __resolvePackagedWasmPath();
}

if (!__wasmFilePath) {
  throw new Error(
    "Cannot find ${packageWasmFileName}.wasm next to this loader, in zig-out/node, or in the ${wasiPackageName} package.",
  );
}

const __wasmFile = __nodeFs.readFileSync(__wasmFilePath);
let __emnapiContext;
${EMNAPI_CONTEXT_LIFECYCLE}
const __wasiRollbackRegistrySymbol = Symbol.for("${WASI_ROLLBACK_REGISTRY_SYMBOL}");
const __wasiRollbackRegistryKey = typeof __filename === "string" ? __filename : __wasmFilePath;

function __getWasiRollbackRegistry() {
  const existing = process[__wasiRollbackRegistrySymbol];
  if (existing !== undefined) {
    if (!(existing instanceof Map)) {
      throw new TypeError("The process-wide zig-napi WASI rollback registry is invalid");
    }
    return existing;
  }
  const registry = new Map();
  Object.defineProperty(process, __wasiRollbackRegistrySymbol, {
    configurable: false,
    enumerable: false,
    value: registry,
    writable: false,
  });
  return registry;
}

const __wasiRollbackRegistry = __getWasiRollbackRegistry();

const __wasiExitListenerSymbol = Symbol.for("napi.rs.wasi.exitListener.v1");

/**
 * One teardown listener per loader file, tracked process-wide rather than per
 * module instance: a rollback retained by one instance is replayed by the next
 * one (the record is process-wide too), and the replay has to be able to remove
 * the listener the first instance registered. The listener belongs to the
 * instance whose context is retained, which is exactly the context a replay
 * destroys.
 */
function __getWasiExitListenerRegistry() {
  const existing = process[__wasiExitListenerSymbol];
  if (existing !== undefined) {
    if (!(existing instanceof Map)) {
      throw new TypeError("The process-wide zig-napi WASI exit listener registry is invalid");
    }
    return existing;
  }
  const registry = new Map();
  Object.defineProperty(process, __wasiExitListenerSymbol, {
    configurable: false,
    enumerable: false,
    value: registry,
    writable: false,
  });
  return registry;
}

const __wasiExitListenerRegistry = __getWasiExitListenerRegistry();

function __completeWasiInitializationRollback(record, cleanupErrors) {
  try {
    if (cleanupErrors.length === 0) {
      if (__wasiRollbackRegistry.get(__wasiRollbackRegistryKey) === record) {
        __wasiRollbackRegistry.delete(__wasiRollbackRegistryKey);
      }
      // A rollback that finished cleanly has nothing left to reclaim, so the
      // process teardown the retry path registered is removed again. Only a
      // retained record keeps it, so re-requiring this file repeatedly cannot
      // accumulate exit listeners.
      __completeWasiDisposal();
      return;
    }
    record.error = __attachCleanupErrors(record.error, cleanupErrors);
  } catch (cleanupError) {
    try {
      record.error = __createCleanupError(
        [record.error, cleanupError],
        "WASI binding initialization and cleanup failed",
      );
    } catch {}
  } finally {
    record.active = false;
    record.promise = undefined;
  }
}

function __runWasiInitializationRollback(record) {
  if (record.active) {
    return;
  }
  record.active = true;
  let rollbackResult;
  try {
    rollbackResult = record.rollback();
  } catch (cleanupError) {
    __completeWasiInitializationRollback(record, [cleanupError]);
    return;
  }
  if (!__isThenable(rollbackResult)) {
    __completeWasiInitializationRollback(record, rollbackResult);
    return;
  }
  record.promise = Promise.resolve(rollbackResult).then(
    (cleanupErrors) => {
      __completeWasiInitializationRollback(record, cleanupErrors);
    },
    (cleanupError) => {
      __completeWasiInitializationRollback(record, [cleanupError]);
    },
  );
}

let __wasiModule;
let __napiModule;
let __wasiExitListenerRegistered = false;

function __removeWasiExitListener() {
  __wasiExitListenerRegistered = false;
  const listener = __wasiExitListenerRegistry.get(__wasiRollbackRegistryKey);
  if (listener === undefined) {
    return;
  }
  __wasiExitListenerRegistry.delete(__wasiRollbackRegistryKey);
  if (typeof process.removeListener === "function") {
    process.removeListener("exit", listener);
  }
}

function __disposeWasiBindingAtExit() {
  __wasiExitListenerRegistered = false;
  // An "exit" handler cannot yield, so it cannot wait for queued settlements
  // the way __startWasiDisposal does - the process is leaving and those
  // promises have no observer left anyway. Run the synchronous teardown
  // directly; every step is idempotent, which also makes this the synchronous
  // finish for a disposal that is still waiting for its drain.
  try {
    __destroyEmnapiContext();
  } catch {}
  try {
    const workerResult = __terminateWasiWorkers();
    if (__isThenable(workerResult)) {
      void Promise.resolve(workerResult).catch(() => {});
    }
  } catch {}
}

function __registerWasiExitListener() {
  if (typeof process.once !== "function") {
    return;
  }
  __wasiExitListenerRegistered = true;
  if (__wasiExitListenerRegistry.has(__wasiRollbackRegistryKey)) {
    return;
  }
  __wasiExitListenerRegistry.set(__wasiRollbackRegistryKey, __disposeWasiBindingAtExit);
  process.once("exit", __disposeWasiBindingAtExit);
}

__completeWasiDisposal = __removeWasiExitListener;
__retainWasiRollbackForRetry = __registerWasiExitListener;

// A rollback that stopped short of destroying its context keeps the record so
// re-requiring this file replays it instead of re-instantiating. Nothing forces
// that replay, so the context is handed to the same synchronous teardown a
// successful load uses: a process that exits without retrying still runs the
// cleanup hooks. The module setup above has to be complete first, because a
// replay that finishes is what removes that teardown again.
const __pendingWasiRollback = __wasiRollbackRegistry.get(__wasiRollbackRegistryKey);
if (__pendingWasiRollback !== undefined) {
  __runWasiInitializationRollback(__pendingWasiRollback);
  throw __pendingWasiRollback.error;
}

${CAPTURE_EMNAPI_AUTO_DESTROY_LISTENER("process")}${instantiationMemoryHint({ threads, initialMemory, maximumMemory })}
try {
  const __finishAutoDestroyCapture = __captureEmnapiAutoDestroyListener();
  try {
    __emnapiContext = __emnapiCreateContext({ autoDestroy: false });
    __emnapiContext.suppressDestroy();
  } finally {
    __finishAutoDestroyCapture?.();
  }

  ;({
    instance: __napiInstance,
    module: __wasiModule,
    napiModule: __napiModule,
  } = __emnapiInstantiateNapiModuleSync(__wasmFile, {
    context: __emnapiContext,
${asyncWorkOptions}    plugins: [__emnapiAsyncWorkPlugin, __emnapiTSFNPlugin],
    wasi: __wasi,
${workerOption}    overwriteImports(importObject) {
      importObject.env = {
        ...importObject.env,
        ...importObject.napi,
        ...importObject.emnapi,
        memory: ${memoryName},
      };
      return importObject;
    },
    beforeInit({ instance }) {
      __napiInstance = instance;
      for (const name of Object.keys(instance.exports)) {
        if (name.startsWith("__napi_register__")) {
          instance.exports[name]();
        }
      }
    },
  }));
  __publishWasiDispose(__napiModule.exports);
  __registerWasiExitListener();
} catch (error) {
  const rollback = {
    active: false,
    error,
    promise: undefined,
    rollback: __rollbackWasiInitialization,
  };
  __wasiRollbackRegistry.set(__wasiRollbackRegistryKey, rollback);
  __runWasiInitializationRollback(rollback);
  throw __annotateWasiInstantiationError(rollback.error);
}
`;
}

/**
 * Browser ESM loader (`<binary>.<suffix>-browser.js`).
 *
 * Threaded flavors pre-create the emnapi worker pool: a browser cannot start a
 * worker while the calling thread is blocked inside a wasm call, so a thread
 * spawned mid-call could never boot and the caller would deadlock waiting for
 * it. The pool is sized from `navigator.hardwareConcurrency` because a
 * constant undersizes both ends of the range, and it must include the async
 * work reservation - emnapi draws both worker kinds from the same pool.
 */
function createWasiBrowserBinding(options) {
  const {
    wasmFileName,
    initialMemory = DEFAULT_INITIAL_MEMORY,
    maximumMemory = DEFAULT_MAXIMUM_MEMORY,
    fs = false,
    asyncInit = false,
    buffer = false,
    errorEvent = false,
    threads = true,
  } = options;
  const effectiveAsyncInit = asyncInit || threads;
  const fsImport = fs
    ? buffer
      ? `\nimport { memfs, Buffer } from "@napi-rs/wasm-runtime/fs";`
      : `\nimport { memfs } from "@napi-rs/wasm-runtime/fs";`
    : "";
  const bufferImport = buffer && !fs ? `\nimport { Buffer } from "buffer";` : "";
  const wasiCreation = fs
    ? `
export const { fs: __fs, vol: __volume } = memfs();

const __wasi = new __WASI({
  version: "preview1",
  fs: __fs,
  preopens: {
    "/": "/",
  },
});`
    : `
const __wasi = new __WASI({
  version: "preview1",
});`;
  const workerFsHandler = fs
    ? `      worker.addEventListener("message", __wasmCreateOnMessageForFsProxy(__fs));\n`
    : "";
  const workerErrorHandler = errorEvent
    ? `      worker.addEventListener("message", (event) => {
        if (event.data && typeof event.data === "object" && event.data.type === "error") {
          const __CustomEvent = globalThis.CustomEvent;
          if (typeof globalThis.dispatchEvent === "function" && typeof __CustomEvent === "function") {
            globalThis.dispatchEvent(new __CustomEvent("napi-rs-worker-error", { detail: event.data }));
          }
        }
      });
`
    : "";
  const emnapiInjectBuffer = buffer ? `  __emnapiContext.features.Buffer = Buffer;\n` : "";
  const emnapiInstantiateImport = effectiveAsyncInit
    ? `instantiateNapiModule as __emnapiInstantiateNapiModule`
    : `instantiateNapiModuleSync as __emnapiInstantiateNapiModuleSync`;
  const emnapiInstantiateCall = effectiveAsyncInit
    ? `await __emnapiInstantiateNapiModule`
    : `__emnapiInstantiateNapiModuleSync`;
  const workerPoolSizeBinding = threads
    ? `${workerPoolValidationHelpers({ maxPoolSize: 64 })}const __asyncWorkPoolSize = __DEFAULT_ASYNC_WORK_POOL_SIZE;
const __hardwareConcurrency = Number(globalThis.navigator?.hardwareConcurrency);
const __workerPoolSize = __normalizeWorkerCount(
  Number.isFinite(__hardwareConcurrency) ? Math.max(2, Math.floor(__hardwareConcurrency)) : 0,
  4,
  __MAX_ASYNC_WORK_POOL_SIZE,
);

`
    : "";
  const reuseWorkerOption = threads
    ? `    reuseWorker: { size: __asyncWorkPoolSize + __workerPoolSize },\n`
    : "";
  const workerRuntimeImport = threads
    ? `  createOnMessage as __wasmCreateOnMessageForFsProxy,\n`
    : "";
  const memoryName = threads ? "__sharedMemory" : "__wasmMemory";
  const asyncWorkPoolOption = `    asyncWorkPoolSize: ${threads ? "__asyncWorkPoolSize" : "0"},\n`;
  const workerOption = threads
    ? `    onCreateWorker() {
      const worker = new Worker(new URL("./wasi-worker-browser.mjs", import.meta.url), {
        type: "module",
      });
      __wasiWorkers.add(worker);
${workerFsHandler}${workerErrorHandler}      return worker;
    },
`
    : "";

  return `/* eslint-disable */
/* auto-generated by zig-napi */
import {
  emnapiAsyncWorkPlugin as __emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin as __emnapiTSFNPlugin,
${workerRuntimeImport}  ${emnapiInstantiateImport},
  WASI as __WASI,
} from "@napi-rs/wasm-runtime";
import { createContext as __emnapiCreateContext } from "@emnapi/runtime";${fsImport}${bufferImport}
${wasiCreation}

// Same candidate order as the Node loader: the artifact next to the loader
// (what a packaged install ships), then the build output directory Zig
// installs into.
const __wasmUrlCandidates = [
  new URL("./${wasmFileName}.wasm", import.meta.url).href,
  new URL("./zig-out/node/${wasmFileName}.wasm", import.meta.url).href,
];
let __wasmResponse;
let __wasmFetchError;
for (const __candidate of __wasmUrlCandidates) {
  try {
    const __response = await globalThis.fetch(__candidate);
    if (__response.ok) {
      __wasmResponse = __response;
      break;
    }
    __wasmFetchError = new Error(
      "Failed to fetch WASI module " +
        __candidate +
        ": " +
        __response.status +
        " " +
        (__response.statusText || "Unknown Status"),
    );
  } catch (__error) {
    __wasmFetchError = __error;
  }
}
if (!__wasmResponse) {
  throw __wasmFetchError ?? new Error("Failed to fetch WASI module " + __wasmUrlCandidates[0]);
}
const __wasmFile = await __wasmResponse.arrayBuffer();

${memoryDeclaration({ threads, initialMemory, maximumMemory, name: memoryName })}${workerPoolSizeBinding}let __emnapiContext;
${EMNAPI_CONTEXT_LIFECYCLE}
let __wasiModule;
let __napiModule;

try {
  __emnapiContext = __emnapiCreateContext({ autoDestroy: false });
  __emnapiContext.suppressDestroy();
${emnapiInjectBuffer}  ;({
    instance: __napiInstance,
    module: __wasiModule,
    napiModule: __napiModule,
  } = ${emnapiInstantiateCall}(__wasmFile, {
    context: __emnapiContext,
${asyncWorkPoolOption}${reuseWorkerOption}    plugins: [__emnapiAsyncWorkPlugin, __emnapiTSFNPlugin],
    wasi: __wasi,
${workerOption}    overwriteImports(importObject) {
      importObject.env = {
        ...importObject.env,
        ...importObject.napi,
        ...importObject.emnapi,
        memory: ${memoryName},
      };
      return importObject;
    },
    beforeInit({ instance }) {
      __napiInstance = instance;
      for (const name of Object.keys(instance.exports)) {
        if (name.startsWith("__napi_register__")) {
          instance.exports[name]();
        }
      }
    },
  }));
  __publishWasiDispose(__napiModule.exports);
} catch (error) {
  const cleanupErrors = await __rollbackWasiInitialization();
  throw __attachCleanupErrors(error, cleanupErrors);
}
`;
}

/**
 * Node.js worker thread script (`wasi-worker.mjs`), threaded flavors only.
 * Every thread that instantiates the module must pass the emnapi plugins: the
 * generated builds link an emnapi archive without the C async work /
 * thread-safe function implementations in the non-threaded case, and the
 * plugins are inert when the threaded archive provides them in C.
 */
const WASI_WORKER_TEMPLATE = (() => {
  const captureEmnapiAutoDestroy = CAPTURE_EMNAPI_AUTO_DESTROY_LISTENER("globalThis.process");
  return `import fs from "node:fs";
import { createRequire } from "node:module";
import { parse } from "node:path";
import { WASI } from "node:wasi";
import { parentPort, Worker, workerData } from "node:worker_threads";

const require = createRequire(import.meta.url);

const {
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  getDefaultContext,
  instantiateNapiModuleSync,
  MessageHandler,
} = require("@napi-rs/wasm-runtime");

if (parentPort) {
  parentPort.on("message", (data) => {
    globalThis.onmessage({ data });
  });
}

Object.assign(globalThis, {
  self: globalThis,
  require,
  Worker,
  importScripts(f) {
    // oxlint-disable-next-line no-eval -- WASI importScripts polyfill
    (0, eval)(fs.readFileSync(f, "utf8") + "//# sourceURL=" + f);
  },
  postMessage(msg) {
    if (parentPort) {
      parentPort.postMessage(msg);
    }
  },
});

const __cwd = process.cwd();
const __rootDir =
  (workerData && typeof workerData.rootDir === "string" && workerData.rootDir) || parse(__cwd).root;
const __hostRoot =
  (workerData && typeof workerData.hostRoot === "string" && workerData.hostRoot) ||
  (process.platform === "android" ? __cwd : __rootDir);
${captureEmnapiAutoDestroy}
const __finishAutoDestroyCapture = __captureEmnapiAutoDestroyListener();
let emnapiContext;
try {
  emnapiContext = getDefaultContext();
  emnapiContext.suppressDestroy();
} finally {
  __finishAutoDestroyCapture?.();
}

const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    const wasi = new WASI({
      version: "preview1",
      env: process.env,
      preopens: {
        [__rootDir]: __hostRoot,
        [__hostRoot]: __hostRoot,
      },
    });

    return instantiateNapiModuleSync(wasmModule, {
      childThread: true,
      wasi,
      context: emnapiContext,
      plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: wasmMemory,
        };
        return importObject;
      },
    });
  },
});

globalThis.onmessage = function (event) {
  handler.handle(event);
};
`;
})();

/**
 * Browser worker script (`wasi-worker-browser.mjs`), threaded flavors only.
 * `fs` gives the worker the memfs-backed WASI filesystem proxy; `errorEvent`
 * forwards worker errors to the host loader as `napi-rs-worker-error` events.
 */
function createWasiBrowserWorkerBinding(fs = false, errorEvent = false) {
  const fsImport = fs
    ? `import {
  createFsProxy,
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  instantiateNapiModuleSync,
  MessageHandler,
  WASI,
} from "@napi-rs/wasm-runtime";
import { memfsExported as __memfsExported } from "@napi-rs/wasm-runtime/fs";

const fs = createFsProxy(__memfsExported);`
    : `import {
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  instantiateNapiModuleSync,
  MessageHandler,
  WASI,
} from "@napi-rs/wasm-runtime";`;
  const errorOutputsDecl = errorEvent ? `\nconst errorOutputs = [];\n` : "";
  const errorOutputsAppend = errorEvent ? `\n    errorOutputs.push([...arguments]);` : "";
  const wasiCreation = fs
    ? `const wasi = new WASI({
      fs,
      preopens: {
        "/": "/",
      },
      print: function () {
        // eslint-disable-next-line no-console
        console.log.apply(console, arguments);
      },
      printErr: function () {
        // eslint-disable-next-line no-console
        console.error.apply(console, arguments);${errorOutputsAppend}
      },
    })`
    : `const wasi = new WASI({
      print: function () {
        // eslint-disable-next-line no-console
        console.log.apply(console, arguments);
      },
      printErr: function () {
        // eslint-disable-next-line no-console
        console.error.apply(console, arguments);${errorOutputsAppend}
      },
    })`;
  const errorHandler = errorEvent
    ? `  onError(error) {
    postMessage({ type: "error", error, errorOutputs });
    errorOutputs.length = 0;
  },`
    : "";

  return `/* eslint-disable */
/* auto-generated by zig-napi */
${fsImport}
${errorOutputsDecl}
const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    ${wasiCreation};
    return instantiateNapiModuleSync(wasmModule, {
      childThread: true,
      wasi,
      plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: wasmMemory,
        };
        return importObject;
      },
    });
  },
${errorHandler}
});

globalThis.onmessage = function (event) {
  handler.handle(event);
};
`;
}

/**
 * Deferred, workerd-safe loader (`<binary>.<suffix>-deferred.js`), generated
 * for non-threaded flavors only.
 *
 * No top-level I/O and no compile-from-bytes: `instantiate()`/`createInstance()`
 * accept a precompiled `WebAssembly.Module` (or a promise for one) so Cloudflare
 * Workers can pass the output of a CompiledWasm module rule. Each instance owns
 * its own emnapi context, memory and teardown, and the singleton is reclaimed on
 * `beforeExit` because a worker isolate can be evicted at any point.
 */
function createWasiDeferredBrowserBinding(options) {
  const {
    wasmFileName,
    initialMemory = DEFAULT_DEFERRED_INITIAL_MEMORY,
    maximumMemory = DEFAULT_MAXIMUM_MEMORY,
    buffer = false,
  } = options;
  const bufferImport = buffer ? `import { Buffer } from "buffer";` : "";
  const emnapiInjectBuffer = buffer ? `    __emnapiContext.features.Buffer = Buffer;\n` : "";

  return `/* eslint-disable */
/* auto-generated by zig-napi */
import {
  emnapiAsyncWorkPlugin as __emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin as __emnapiTSFNPlugin,
  instantiateNapiModule as __emnapiInstantiateNapiModule,
  WASI as __WASI,
} from "@napi-rs/wasm-runtime";
import { createContext as __emnapiCreateContext } from "@emnapi/runtime";
${bufferImport}
/**
 * Accepts ONLY a precompiled WebAssembly.Module, or a Promise resolving to one
 * (e.g. \`import mod from "./${wasmFileName}.wasm"\` under a CompiledWasm module
 * rule). Byte buffers, URLs and Response objects are rejected: they require
 * dynamic Wasm compilation, which Cloudflare Workers disallows.
 */
async function __resolveModule(__wasmInput) {
  const __module = await __wasmInput;
  // Brand check, not instanceof: WebAssembly.Module.imports throws unless its
  // argument is a genuine WebAssembly.Module, so prototype-spoofed byte buffers
  // are rejected while cross-realm Module instances are accepted.
  try {
    WebAssembly.Module.imports(__module);
  } catch {
    throw new TypeError(
      "instantiate() and createInstance() expect a precompiled WebAssembly.Module (or a Promise resolving to one), " +
        "e.g. import mod from './${wasmFileName}.wasm' under a CompiledWasm module rule / wrangler module import. " +
        "Byte buffers, URLs and Response objects require dynamic Wasm compilation, which Cloudflare Workers disallows.",
    );
  }
  return __module;
}

let __normalizedModules;

function __rememberNormalizedModule(__module, __normalizedModule) {
  if (!__normalizedModules) {
    __normalizedModules = new WeakMap();
  }
  __normalizedModules.set(__module, __normalizedModule);
  return __normalizedModule;
}

async function __normalizeModuleForEmnapi(__module) {
  if (__module instanceof WebAssembly.Module) {
    return __module;
  }
  if (__normalizedModules) {
    const __normalizedModule = __normalizedModules.get(__module);
    if (__normalizedModule) {
      return __normalizedModule;
    }
  }
  // @emnapi/core performs realm-local instanceof checks after accepting the
  // module. Structured cloning preserves compiled code without compiling bytes
  // and produces a Module owned by the current realm.
  if (typeof structuredClone === "function") {
    try {
      const __normalizedModule = structuredClone(__module);
      if (__normalizedModule instanceof WebAssembly.Module) {
        return __rememberNormalizedModule(__module, __normalizedModule);
      }
    } catch {}
  }
  // MessageChannel uses the same structured-clone semantics and covers hosts
  // that expose it but not the structuredClone function.
  if (typeof MessageChannel === "function") {
    let __channel;
    try {
      __channel = new MessageChannel();
      const __normalizedModule = await new Promise((resolve, reject) => {
        __channel.port1.onmessage = (event) => resolve(event.data);
        __channel.port1.onmessageerror = () => reject(new TypeError("Failed to clone WebAssembly.Module"));
        try {
          __channel.port2.postMessage(__module);
        } catch (error) {
          reject(error);
        }
      });
      if (__normalizedModule instanceof WebAssembly.Module) {
        return __rememberNormalizedModule(__module, __normalizedModule);
      }
    } catch {
    } finally {
      try {
        __channel?.port1.close();
      } catch {}
      try {
        __channel?.port2.close();
      } catch {}
    }
  }
  // Last-resort compatibility for genuine, extensible foreign Modules.
  try {
    Object.setPrototypeOf(__module, WebAssembly.Module.prototype);
  } catch {}
  if (__module instanceof WebAssembly.Module) {
    return __module;
  }
  throw new TypeError(
    "This host cannot normalize a cross-realm WebAssembly.Module; provide structuredClone or MessageChannel support.",
  );
}

function __captureEmnapiAutoDestroyListener() {
  const __process = typeof process === "object" && process !== null ? process : undefined;
  if (
    !__process ||
    typeof __process.prependListener !== "function" ||
    typeof __process.removeListener !== "function"
  ) {
    return;
  }
  let __autoDestroyListener;
  const __captureListener = (__event, __listener) => {
    if (__event === "beforeExit" && __autoDestroyListener === undefined) {
      __autoDestroyListener = __listener;
    }
  };
  try {
    // Run before existing newListener hooks so a hook that registers its own
    // beforeExit listener cannot be mistaken for emnapi's registration.
    __process.prependListener("newListener", __captureListener);
  } catch {
    return;
  }
  return () => {
    try {
      __process.removeListener("newListener", __captureListener);
    } catch {}
    if (__autoDestroyListener !== undefined) {
      try {
        __process.removeListener("beforeExit", __autoDestroyListener);
      } catch {}
    }
  };
}

function __attachCleanupError(__error, __cleanupError) {
  try {
    if (
      __error &&
      (typeof __error === "object" || typeof __error === "function") &&
      __error.cause === undefined
    ) {
      __error.cause = __cleanupError;
    }
  } catch {}
}

// Mirror the primitive @emnapi/core schedules its threadsafe-function dispatch
// on, so the drain turns below interleave with that dispatch instead of racing
// ahead of it on a faster queue.
const __scheduleMacrotask = (function () {
  if (typeof setImmediate === "function") {
    return function (__callback) {
      setImmediate(__callback);
    };
  }
  const __MessageChannel = globalThis.MessageChannel;
  if (typeof __MessageChannel === "function") {
    return function (__callback) {
      const __channel = new __MessageChannel();
      __channel.port1.onmessage = function () {
        __channel.port1.onmessage = null;
        try {
          __channel.port1.close();
        } catch {}
        try {
          __channel.port2.close();
        } catch {}
        __callback();
      };
      __channel.port2.postMessage(null);
    };
  }
  return function (__callback) {
    setTimeout(__callback, 0);
  };
})();

const __WASM_ENV_CLEANUP_DRAIN_TURNS = 128;
const __WASM_ENV_CLEANUP_BLIND_DRAIN_TURNS = 4;

/**
 * Waits, in real event-loop turns, for the settlements queued by
 * \`napi_prepare_wasm_env_cleanup()\` to reach JavaScript. \`Context.destroy()\`
 * runs the threadsafe function cleanup hook, which drains the queue with a null
 * env and discards it, so destroying without yielding first strands exactly the
 * promises the barrier exists to settle. A counter that is still nonzero when
 * the bounded wait runs out rejects as retryable
 * (\`ERR_NAPI_WASI_CLEANUP_PENDING\`) instead of destroying over the queue.
 */
function __drainWasmEnvCleanup(__instance) {
  const __pending = __instance?.exports.napi_wasm_env_cleanup_pending;
  const __observable = typeof __pending === "function";
  if (__observable) {
    let __queued;
    try {
      __queued = __pending();
    } catch {
      return;
    }
    if (!__queued) {
      return;
    }
  }
  const __limit = __observable ? __WASM_ENV_CLEANUP_DRAIN_TURNS : __WASM_ENV_CLEANUP_BLIND_DRAIN_TURNS;
  return (async () => {
    let __queued = 0;
    for (let __turn = 0; __turn < __limit; __turn++) {
      await new Promise((resolve) => {
        __scheduleMacrotask(resolve);
      });
      if (!__observable) {
        continue;
      }
      try {
        __queued = __pending();
      } catch {
        return;
      }
      if (!__queued) {
        return;
      }
    }
    if (!__observable) {
      // Blind wait: without napi_wasm_env_cleanup_pending the bound IS the
      // contract - there is nothing to consult, so finishing the turns is
      // finishing the drain.
      return;
    }
    const __drainError = new Error(
      "the wasm environment still reports " +
        __queued +
        " queued settlement(s) after " +
        __limit +
        " event-loop turns; the context was not destroyed - retry dispose() to wait for the queue again",
    );
    __drainError.code = "ERR_NAPI_WASI_CLEANUP_PENDING";
    throw __drainError;
  })();
}

function __createLifecycleReentryError(__operation) {
  const __error = new Error(
    __operation +
      "() cannot run while an emnapi Context.destroy() call is still active; await the original cleanup promise instead.",
  );
  __error.code = "ERR_NAPI_WASI_LIFECYCLE_REENTRY";
  return __error;
}

const __managedEmnapiContextDestroyers = new Set();
let __managedCleanupProcess;
let __managedBeforeExitListener;
let __managedDestroyPromise;
let __managedDestroyersInFlight;
let __managedBeforeExitRegistrationRetryCount = 0;
let __managedBeforeExitRegistrationRetryScheduled = false;
let __moduleLifecycleDestroyDepth = 0;

function __removeManagedEmnapiCleanupListeners() {
  const __process = __managedCleanupProcess;
  const __beforeExitListener = __managedBeforeExitListener;
  __managedCleanupProcess = undefined;
  __managedBeforeExitListener = undefined;
  __managedBeforeExitRegistrationRetryCount = 0;
  if (__process && __beforeExitListener) {
    try {
      __process.removeListener("beforeExit", __beforeExitListener);
    } catch {}
  }
}

function __scheduleManagedBeforeExitListenerRegistration() {
  if (
    !__managedCleanupProcess ||
    __managedBeforeExitListener ||
    __managedEmnapiContextDestroyers.size === 0 ||
    __managedBeforeExitRegistrationRetryScheduled ||
    __managedBeforeExitRegistrationRetryCount >= 3
  ) {
    return;
  }
  __managedBeforeExitRegistrationRetryScheduled = true;
  __managedBeforeExitRegistrationRetryCount++;
  queueMicrotask(() => {
    __managedBeforeExitRegistrationRetryScheduled = false;
    if (
      !__managedCleanupProcess ||
      __managedBeforeExitListener ||
      __managedEmnapiContextDestroyers.size === 0
    ) {
      return;
    }
    try {
      __registerManagedBeforeExitListener();
    } catch {}
  });
}

function __registerManagedBeforeExitListener() {
  if (!__managedCleanupProcess || __managedBeforeExitListener) {
    return;
  }
  try {
    __managedCleanupProcess.once("beforeExit", __destroyManagedEmnapiContextsBeforeExit);
  } catch (error) {
    __scheduleManagedBeforeExitListenerRegistration();
    throw error;
  }
  __managedBeforeExitListener = __destroyManagedEmnapiContextsBeforeExit;
  __managedBeforeExitRegistrationRetryCount = 0;
}

function __settleManagedEmnapiContextDestroy(__promise) {
  if (__managedDestroyPromise === __promise) {
    __managedDestroyPromise = undefined;
    __managedDestroyersInFlight = undefined;
  }
  if (__managedEmnapiContextDestroyers.size === 0) {
    __removeManagedEmnapiCleanupListeners();
    return;
  }
  try {
    __registerManagedBeforeExitListener();
  } catch {}
}

function __destroyManagedEmnapiContexts(__excludedDestroyers) {
  if (__managedDestroyPromise) {
    return __managedDestroyPromise;
  }
  const __destroyers = Array.from(__managedEmnapiContextDestroyers).filter(
    (__destroy) => !__excludedDestroyers?.has(__destroy),
  );
  if (__destroyers.length === 0) {
    return Promise.resolve();
  }
  let __resolveDestroy;
  let __rejectDestroy;
  const __promise = new Promise((resolve, reject) => {
    __resolveDestroy = resolve;
    __rejectDestroy = reject;
  });
  __managedDestroyPromise = __promise;
  __managedDestroyersInFlight = new Set(__destroyers);
  void Promise.all(
    __destroyers.map((__destroy) => {
      try {
        return Promise.resolve(__destroy()).then(
          () => ({ failed: false }),
          (error) => ({ failed: true, error }),
        );
      } catch (error) {
        return { failed: true, error };
      }
    }),
  ).then(
    (__results) => {
      let __primaryError;
      let __failed = false;
      for (const __result of __results) {
        if (!__result.failed) {
          continue;
        }
        if (!__failed) {
          __failed = true;
          __primaryError = __result.error;
        } else {
          __attachCleanupError(__primaryError, __result.error);
        }
      }
      if (__failed) {
        __rejectDestroy(__primaryError);
      } else {
        __resolveDestroy();
      }
    },
    __rejectDestroy,
  );
  void __promise.then(
    () => {
      __settleManagedEmnapiContextDestroy(__promise);
    },
    () => {
      __settleManagedEmnapiContextDestroy(__promise);
    },
  );
  return __promise;
}

async function __drainManagedEmnapiContexts(__excludedDestroyers) {
  const __attemptedDestroyers = new Set(__excludedDestroyers);
  let __primaryError;
  let __failed = false;
  for (;;) {
    let __promise = __managedDestroyPromise;
    let __destroyers = __managedDestroyersInFlight;
    if (!__promise) {
      __promise = __destroyManagedEmnapiContexts(__attemptedDestroyers);
      __destroyers = __managedDestroyersInFlight;
      if (!__destroyers) {
        break;
      }
    }
    for (const __destroy of __destroyers) {
      __attemptedDestroyers.add(__destroy);
    }
    try {
      await __promise;
    } catch (error) {
      if (!__failed) {
        __failed = true;
        __primaryError = error;
      } else {
        __attachCleanupError(__primaryError, error);
      }
    }
  }
  if (__failed) {
    throw __primaryError;
  }
}

function __destroyManagedEmnapiContextsBeforeExit() {
  // A once listener is consumed before Node invokes it, including when another
  // cleanup batch is still pending.
  __managedBeforeExitListener = undefined;
  if (__managedDestroyPromise) {
    return;
  }
  void __destroyManagedEmnapiContexts().catch((error) => {
    queueMicrotask(() => {
      throw error;
    });
  });
}

function __registerManagedEmnapiContext(__process, __destroy) {
  __managedEmnapiContextDestroyers.add(__destroy);
  if (
    !__managedCleanupProcess &&
    __process &&
    typeof __process.once === "function" &&
    typeof __process.removeListener === "function"
  ) {
    __managedCleanupProcess = __process;
  }
  let __registered = true;
  return () => {
    if (!__registered) {
      return;
    }
    __registered = false;
    __managedEmnapiContextDestroyers.delete(__destroy);
    if (__managedEmnapiContextDestroyers.size === 0) {
      __removeManagedEmnapiCleanupListeners();
    }
  };
}

/**
 * Creates one emnapi context with a retryable, reentrancy-checked destroyer.
 * The barrier runs before \`Context.destroy()\` so runtime-owned promises are
 * settled while this environment can still call JavaScript.
 */
async function __createManagedEmnapiContext(__prepareEnvCleanup) {
  const __process = typeof process === "object" && process !== null ? process : undefined;
  const __finishAutoDestroyCapture = __captureEmnapiAutoDestroyListener();
  let __emnapiContext;
  let __contextInitializationError;
  let __contextInitializationFailed = false;
  try {
    __emnapiContext = __emnapiCreateContext({ autoDestroy: false });
    // emnapi 2.x registers an unconditional process.once("beforeExit")
    // auto-destroy listener from the Context constructor, and suppressDestroy()
    // only neutralizes its callback without removing it. This loader stays
    // side-effect free per instance, so the listener is captured and removed;
    // suppressDestroy() remains the safety net when removal is unavailable.
    __emnapiContext.suppressDestroy();
  } catch (error) {
    __contextInitializationError = error;
    __contextInitializationFailed = true;
  } finally {
    __finishAutoDestroyCapture?.();
  }
  if (__emnapiContext === undefined) {
    throw __contextInitializationError;
  }
  let __disposed = false;
  let __destroying = false;
  let __destroyPromise;
  let __cleanupRegistered = false;
  let __unregisterCleanup;
  const __destroy = (__blocksModuleLifecycle = false) => {
    if (__disposed) {
      return;
    }
    if (__destroying) {
      throw __createLifecycleReentryError("dispose");
    }
    if (__destroyPromise) {
      return __destroyPromise;
    }
    __destroying = true;
    let __result;
    const __finishDestroyInvocation = () => {
      __destroying = false;
    };
    const __finishModuleLifecycleDestroy = () => {
      if (__blocksModuleLifecycle) {
        __blocksModuleLifecycle = false;
        __moduleLifecycleDestroyDepth--;
      }
    };
    if (__blocksModuleLifecycle) {
      __moduleLifecycleDestroyDepth++;
    }
    try {
      __prepareEnvCleanup?.();
      __result = __emnapiContext.destroy();
    } catch (error) {
      __finishDestroyInvocation();
      __finishModuleLifecycleDestroy();
      throw error;
    }
    let __then;
    try {
      if (__result !== null && (typeof __result === "object" || typeof __result === "function")) {
        __then = __result.then;
      }
    } catch (error) {
      __finishDestroyInvocation();
      __finishModuleLifecycleDestroy();
      throw error;
    }
    if (typeof __then === "function") {
      let __resolveResult;
      let __rejectResult;
      const __resultPromise = new Promise((resolve, reject) => {
        __resolveResult = resolve;
        __rejectResult = reject;
      });
      const __promise = __resultPromise.then(
        (value) => {
          __finishDestroyInvocation();
          __finishModuleLifecycleDestroy();
          __disposed = true;
          __destroyPromise = undefined;
          __unregisterCleanup?.();
          return value;
        },
        (error) => {
          __finishDestroyInvocation();
          __finishModuleLifecycleDestroy();
          __destroyPromise = undefined;
          throw error;
        },
      );
      __destroyPromise = __promise;
      try {
        Reflect.apply(__then, __result, [__resolveResult, __rejectResult]);
      } catch (error) {
        __rejectResult(error);
      }
      return __promise;
    }
    __finishDestroyInvocation();
    __finishModuleLifecycleDestroy();
    __disposed = true;
    __unregisterCleanup?.();
  };
  const __destroyForModuleLifecycle = () => __destroy(true);
  const __registerCleanup = (__beforeExitDestroy = __destroyForModuleLifecycle) => {
    if (__cleanupRegistered || __disposed) {
      return;
    }
    __unregisterCleanup = __registerManagedEmnapiContext(__process, __beforeExitDestroy);
    __cleanupRegistered = true;
    __registerManagedBeforeExitListener();
  };
  if (__contextInitializationFailed) {
    let __registrationError;
    let __registrationFailed = false;
    try {
      __registerCleanup();
    } catch (error) {
      __attachCleanupError(__contextInitializationError, error);
      __registrationError = error;
      __registrationFailed = true;
    }
    try {
      await __destroyForModuleLifecycle();
    } catch (error) {
      __attachCleanupError(__registrationFailed ? __registrationError : __contextInitializationError, error);
      try {
        __registerManagedBeforeExitListener();
      } catch {}
    }
    throw __contextInitializationError;
  }
  return {
    context: __emnapiContext,
    destroy: __destroy,
    destroyForModuleLifecycle: __destroyForModuleLifecycle,
    registerCleanup: __registerCleanup,
  };
}

async function __createInstance(__wasmInput, __beforeExitDestroy, __onManagedDestroyer) {
  const __module = await __resolveModule(__wasmInput);
  const __emnapiModule = await __normalizeModuleForEmnapi(__module);
  const __wasi = new __WASI({
    version: "preview1",
  });
  // The wasm module is linked with \`--import-memory\`, so a Memory must be
  // provided. It is allocated in function scope (workerd bans global scope
  // allocation) and is not shared (no threads, no SharedArrayBuffer). Allocate
  // it before the emnapi context so a host memory-limit failure cannot leak a
  // context that never reaches instantiation.
  const __wasmMemory = new WebAssembly.Memory({
    initial: ${initialMemory},
    maximum: ${maximumMemory},
  });
  let __lifecycleState = "pending";
  let __destroyEmnapiContext;
  let __destroyOwnedContext;
  let __destroyManagedOwnedContext;
  let __napiInstance;
  let __wasmEnvCleanupRan = false;
  let __wasmEnvCleanupPrepared = false;
  let __wasmEnvCleanupDrained = false;
  let __wasmEnvCleanupDrainPromise;
  const __prepareEnvCleanup = () => {
    if (__wasmEnvCleanupPrepared) {
      return;
    }
    const __prepareWasmEnvCleanup = __napiInstance?.exports.napi_prepare_wasm_env_cleanup;
    if (typeof __prepareWasmEnvCleanup === "function") {
      __prepareWasmEnvCleanup();
      __wasmEnvCleanupRan = true;
    }
    __wasmEnvCleanupPrepared = true;
  };
  // The barrier + settlement drain, hoisted out of the context destroyer so the
  // drain can yield without widening the destroyer's reentry window. Both
  // yielding paths run it - dispose() and the initialization-failure rollback -
  // while the destroyer still runs the barrier itself (idempotently) for the one
  // path that cannot yield: managed beforeExit cleanup of a failed rollback.
  const __prepareForDisposal = () => {
    if (__wasmEnvCleanupDrained) {
      return;
    }
    if (__wasmEnvCleanupDrainPromise) {
      return __wasmEnvCleanupDrainPromise;
    }
    __prepareEnvCleanup();
    if (!__wasmEnvCleanupRan) {
      return;
    }
    const __drained = __drainWasmEnvCleanup(__napiInstance);
    if (!__drained || typeof __drained.then !== "function") {
      __wasmEnvCleanupDrained = true;
      return;
    }
    const __tracked = __drained.then(
      (__value) => {
        __wasmEnvCleanupDrained = true;
        __wasmEnvCleanupDrainPromise = undefined;
        return __value;
      },
      (__error) => {
        __wasmEnvCleanupDrainPromise = undefined;
        throw __error;
      },
    );
    __wasmEnvCleanupDrainPromise = __tracked;
    return __tracked;
  };
  const __destroyBeforeExit = __beforeExitDestroy
    ? async () => {
        if (__lifecycleState === "failed") {
          await __destroyManagedOwnedContext();
          return;
        }
        __lifecycleState = "disposal";
        try {
          await __beforeExitDestroy();
        } catch (error) {
          if (__lifecycleState !== "failed") {
            throw error;
          }
          // The singleton's initialization rejection is already observable
          // through instantiate() and dispose(). Managed beforeExit cleanup
          // owns only context destruction, including retrying a failed
          // rollback.
          await __destroyManagedOwnedContext();
        }
      }
    : undefined;
  const {
    context: __emnapiContext,
    destroy,
    destroyForModuleLifecycle,
    registerCleanup: __registerCleanup,
  } = await __createManagedEmnapiContext(__prepareEnvCleanup);
  __destroyEmnapiContext = destroy;
  __destroyOwnedContext = () => __destroyEmnapiContext();
  __destroyManagedOwnedContext = destroyForModuleLifecycle;
  try {
    if (__destroyBeforeExit) {
      __onManagedDestroyer(__destroyBeforeExit);
      await __registerCleanup(__destroyBeforeExit);
    }
${emnapiInjectBuffer}    let __napiModule;
    ;({
      instance: __napiInstance,
      napiModule: __napiModule,
    } = await __emnapiInstantiateNapiModule(__emnapiModule, {
      context: __emnapiContext,
      asyncWorkPoolSize: 0,
      plugins: [__emnapiAsyncWorkPlugin, __emnapiTSFNPlugin],
      wasi: __wasi,
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: __wasmMemory,
        };
        return importObject;
      },
      beforeInit({ instance }) {
        __napiInstance = instance;
        for (const name of Object.keys(instance.exports)) {
          if (name.startsWith("__napi_register__")) {
            instance.exports[name]();
          }
        }
      },
    }));
    if (__lifecycleState === "pending") {
      __lifecycleState = "succeeded";
    }
    return {
      exports: __napiModule.exports,
      async dispose() {
        if (__lifecycleState !== "failed") {
          __lifecycleState = "disposal";
        }
        // Settle what the barrier cancelled before the environment stops
        // accepting JavaScript calls. Undefined unless something is queued, so
        // an idle disposal is not delayed by a single turn.
        const __drained = __prepareForDisposal();
        if (__drained) {
          await __drained;
        }
        return __beforeExitDestroy ? __destroyManagedOwnedContext() : __destroyOwnedContext();
      },
    };
  } catch (error) {
    __lifecycleState = "failed";
    // Instantiation can fail after registration has run, and registration runs
    // with a live environment: a module-init hook can start async work and then
    // return an error, and the promise it created may already have escaped into
    // JavaScript. Settle what the barrier cancels before the context is
    // destroyed, exactly like dispose() does; destroying without yielding
    // discards the queue with a null env.
    let __settlementsUnreached = false;
    try {
      const __drained = __prepareForDisposal();
      if (__drained) {
        await __drained;
      }
    } catch (drainError) {
      __attachCleanupError(error, drainError);
      __settlementsUnreached = true;
    }
    let __registrationError;
    let __registrationFailed = false;
    if (!__beforeExitDestroy) {
      try {
        // Independent instances are caller-owned while pending and after
        // success. Register only a failed rollback so cleanup stays retryable.
        await __registerCleanup();
      } catch (registrationError) {
        __attachCleanupError(error, registrationError);
        __registrationError = registrationError;
        __registrationFailed = true;
      }
    }
    if (__settlementsUnreached) {
      // The barrier or the drain did not finish, so the settlements it queued
      // are still in the threadsafe-function queue. Destroying now runs the
      // cleanup hook that drains that queue with a null env and discards it,
      // stranding a promise that already escaped into JavaScript. dispose()
      // refuses to destroy for exactly this reason, so this path refuses too:
      // the registration above leaves the context in the managed set, so
      // beforeExit destroys it and dispose() can retry it.
      try {
        __registerManagedBeforeExitListener();
      } catch {}
      throw error;
    }
    try {
      await __destroyManagedOwnedContext();
    } catch (disposeError) {
      // Initialization is the primary failure. Preserve it even if cleanup also
      // fails, while retaining the cleanup error when the value is extensible
      // and has no existing cause.
      __attachCleanupError(__registrationFailed ? __registrationError : error, disposeError);
      try {
        __registerManagedBeforeExitListener();
      } catch {}
    }
    throw error;
  }
}

/**
 * Create an independent instance. Call dispose() when the instance is no longer
 * needed so emnapi cleanup hooks run deterministically.
 */
export async function createInstance(__wasmInput) {
  return __createInstance(__wasmInput);
}

let __defaultModulePromise;
let __defaultInstancePromise;
let __defaultDisposePromise;
let __defaultDisposalStarted = false;
const __defaultManagedDestroyers = new WeakMap();
let __moduleDisposePromise;

/**
 * Instantiate a module-local singleton. Concurrent and repeated calls with the
 * same module share one instance and one Memory allocation.
 */
export function instantiate(__wasmInput) {
  const __modulePromise = __resolveModule(__wasmInput);
  if (__moduleLifecycleDestroyDepth !== 0) {
    void __modulePromise.catch(() => {});
    return Promise.reject(__createLifecycleReentryError("instantiate"));
  }
  if (__moduleDisposePromise) {
    void __modulePromise.catch(() => {});
    return __moduleDisposePromise.then(() => instantiate(__modulePromise));
  }
  if (__defaultDisposalStarted) {
    // Observe rejected input immediately, but preserve lifecycle ordering and
    // error precedence by instantiating only after disposal succeeds. A failed
    // disposal retains the old instance only so its cleanup can be retried.
    void __modulePromise.catch(() => {});
    const __disposePromise = __defaultDisposePromise ?? dispose();
    return __disposePromise.then(() => instantiate(__modulePromise));
  }
  if (!__defaultInstancePromise) {
    __defaultModulePromise = __modulePromise;
    const __instancePromise = __modulePromise.then((__module) =>
      __createInstance(__module, __disposeDefaultInstance, (__managedDestroyer) => {
        __defaultManagedDestroyers.set(__instancePromise, __managedDestroyer);
      }),
    );
    __defaultInstancePromise = __instancePromise;
    void __instancePromise.catch(() => {
      if (__defaultInstancePromise === __instancePromise) {
        __defaultInstancePromise = undefined;
        __defaultModulePromise = undefined;
      }
    });
    return __instancePromise.then((__instance) => __instance.exports);
  }
  const __defaultModulePromiseForCall = __defaultModulePromise;
  const __defaultInstancePromiseForCall = __defaultInstancePromise;
  return Promise.all([__defaultModulePromiseForCall, __modulePromise]).then(
    async ([__defaultModule, __module]) => {
      if (__defaultModule !== __module) {
        throw new Error(
          "instantiate() already owns a different WebAssembly.Module; call dispose() first or use createInstance() for independent instances.",
        );
      }
      return (await __defaultInstancePromiseForCall).exports;
    },
  );
}

async function __disposeDefaultInstance(__onDestroy) {
  if (__defaultDisposePromise) {
    return __defaultDisposePromise;
  }
  const __instancePromise = __defaultInstancePromise;
  if (!__instancePromise) {
    __defaultDisposalStarted = false;
    return;
  }
  __defaultDisposalStarted = true;
  const __disposePromise = (async () => {
    let __instance;
    try {
      __instance = await __instancePromise;
    } catch (error) {
      const __managedDestroyer = __defaultManagedDestroyers.get(__instancePromise);
      if (__managedDestroyer) {
        __onDestroy?.(__managedDestroyer);
      }
      __defaultManagedDestroyers.delete(__instancePromise);
      throw error;
    }
    const __managedDestroyer = __defaultManagedDestroyers.get(__instancePromise);
    if (__managedDestroyer) {
      __onDestroy?.(__managedDestroyer);
    }
    await __instance.dispose();
    if (__defaultInstancePromise === __instancePromise) {
      __defaultInstancePromise = undefined;
      __defaultModulePromise = undefined;
      __defaultDisposalStarted = false;
    }
    __defaultManagedDestroyers.delete(__instancePromise);
  })();
  __defaultDisposePromise = __disposePromise;
  try {
    await __disposePromise;
  } finally {
    if (__defaultDisposePromise === __disposePromise) {
      __defaultDisposePromise = undefined;
    }
  }
}

async function __dispose() {
  let __defaultDisposeError;
  let __defaultDisposeFailed = false;
  let __attemptedDefaultDestroyer;
  try {
    await __disposeDefaultInstance((__destroyer) => {
      __attemptedDefaultDestroyer = __destroyer;
    });
  } catch (error) {
    __defaultDisposeError = error;
    __defaultDisposeFailed = true;
  }
  const __excludedDestroyers = new Set();
  if (__defaultDisposeFailed && __attemptedDefaultDestroyer) {
    __excludedDestroyers.add(__attemptedDefaultDestroyer);
  }
  try {
    await __drainManagedEmnapiContexts(__excludedDestroyers);
  } catch (error) {
    if (!__defaultDisposeFailed) {
      throw error;
    }
    if (error !== __defaultDisposeError) {
      __attachCleanupError(__defaultDisposeError, error);
    }
  }
  if (__defaultDisposeFailed) {
    throw __defaultDisposeError;
  }
}

/**
 * Dispose the singleton created by instantiate(). A later call may create a
 * fresh instance, including from a different module. This also retries cleanup
 * retained after a failed initialization rollback.
 */
export function dispose() {
  if (__moduleLifecycleDestroyDepth !== 0) {
    return Promise.reject(__createLifecycleReentryError("dispose"));
  }
  if (__moduleDisposePromise) {
    return __moduleDisposePromise;
  }
  let __resolveDispose;
  let __rejectDispose;
  const __promise = new Promise((resolve, reject) => {
    __resolveDispose = resolve;
    __rejectDispose = reject;
  });
  __moduleDisposePromise = __promise;
  void __dispose().then(__resolveDispose, __rejectDispose);
  void __promise.then(
    () => {
      if (__moduleDisposePromise === __promise) {
        __moduleDisposePromise = undefined;
      }
    },
    () => {
      if (__moduleDisposePromise === __promise) {
        __moduleDisposePromise = undefined;
      }
    },
  );
  return __promise;
}
`;
}

function createWasiDeferredBrowserBindingTypeDef(packageName) {
  return `export type WasiBinding = typeof import("${packageName}");

export type WasiModuleInput = WebAssembly.Module | PromiseLike<WebAssembly.Module>;

export interface WasiInstance {
  readonly exports: WasiBinding;
  dispose(): Promise<void>;
}

export function instantiate(wasmInput: WasiModuleInput): Promise<WasiBinding>;
export function createInstance(wasmInput: WasiModuleInput): Promise<WasiInstance>;
/** Dispose the singleton and retry retained failed-initialization cleanup. */
export function dispose(): Promise<void>;
`;
}

/**
 * CommonJS declaration emitted next to `<binary>.<suffix>.cjs`. The binding is
 * the binding module re-exported through \`export =\`, which is what the CJS
 * loader provides.
 */
function createWasiBindingTypeDef(bindingModuleSpecifier, hasTypeDef = true) {
  const bindingType = `typeof import("${bindingModuleSpecifier}")`;
  if (hasTypeDef) {
    return `declare const binding: ${bindingType};
export = binding;
`;
  }
  return `declare const binding: Record<string, unknown>;
export = binding;
`;
}

/** Root `browser.js` entry: re-exports the wasm package of the flavor. */
function createWasiBrowserEntry(packageName, platformArchABI, idents = []) {
  const specifier = optionalPackageName(packageName, platformArchABI);
  return (
    `export * from "${specifier}";\n` +
    (idents.length === 0 ? `export { default } from "${specifier}";\n` : "")
  );
}

module.exports = {
  DEFAULT_DEFERRED_INITIAL_MEMORY,
  DEFAULT_INITIAL_MEMORY,
  DEFAULT_MAXIMUM_MEMORY,
  MAX_WASM_PAGES,
  MIN_WASM_PAGES,
  WASI_DISPOSE_SYMBOL,
  WASI_FLAVORS,
  WASI_ROLLBACK_REGISTRY_SYMBOL,
  WASM_PAGE_SIZE,
  WasiConfigError,
  WASI_WORKER_TEMPLATE,
  collectWasiFlavors,
  createWasiBindingTypeDef,
  createWasiBrowserBinding,
  createWasiBrowserEntry,
  createWasiBrowserWorkerBinding,
  createWasiDeferredBrowserBinding,
  createWasiDeferredBrowserBindingTypeDef,
  createWasiNodeBinding,
  getWasiFlavor,
  isWasiTargetName,
  isWasiThreadsTargetName,
  managedWasiFilesByFlavor,
  managedWasiFileNames,
  normalizeWasiTargetName,
  optionalPackageName,
  resolveWasmConfig,
  wasiFlavorFileNames,
  wasiLoaderSuffix,
  wasiMemoryBuildArgs,
};
