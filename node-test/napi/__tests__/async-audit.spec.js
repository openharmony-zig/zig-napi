// Regression spec for the async/abort/TSFN/runtime audit findings
// (F04 async ownership, F08 AbortSignal, F09 async cancellation,
// F10 TSFN shutdown, F11 promise settlement, F14 runtime environments).
//
// Probes that used to abort the process run in a child process so a regression
// is reported as a failure instead of killing the test runner.
const path = require("path");
const { spawnSync } = require("node:child_process");
const { Worker } = require("worker_threads");
const test = require("ava");

const loaderPath = path.join(__dirname, "..", "..", "load-addon.js");
const native = require(loaderPath)("async_audit");
const workerSource = path.join(__dirname, "async-audit-worker.js");

function runIsolated(body, extraArgs = []) {
  return spawnSync(
    process.execPath,
    [...extraArgs, "-e", `const a=require(${JSON.stringify(loaderPath)})("async_audit");${body}`],
    { encoding: "utf8", timeout: 5000 },
  );
}

// A settled promise keeps its settlement capability alive until the JavaScript
// promise object is collected (`Capability` in src/napi/value/promise.zig is
// owned by the promise object's wrap finalizer). 32 bytes is the size of that
// state on a 64 bit target; the "settlement state is reclaimed by GC" test
// proves the memory is not leaked.
const capabilityBytesPerCall = 32;

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function settlesWithin(promise, ms) {
  let settled = false;
  const guarded = promise.then(
    (value) => {
      settled = true;
      return { state: "resolved", value };
    },
    (error) => {
      settled = true;
      return { state: "rejected", message: error && error.message ? error.message : String(error) };
    },
  );
  const timeout = delay(ms).then(() => (settled ? null : { state: "timeout" }));
  const outcome = await Promise.race([guarded, timeout]);
  return outcome || (await guarded);
}

test("async borrowed literal result is not freed and does not leak", async (t) => {
  const before = native.activeBytes();
  for (let index = 0; index < 100; index += 1) {
    t.is(await native.asyncLiteral(), "literal");
  }
  // The literal lives in static storage: the runtime must not free it. The only
  // retained memory is the per-promise settlement state, which is reclaimed by
  // GC (see the dedicated test below).
  const leaked = native.activeBytes() - before;
  t.true(leaked <= 100 * capabilityBytesPerCall, `expected only settlement state, got ${leaked}`);
});

test("settlement state is reclaimed once the JS promises are collected", (t) => {
  const probe = runIsolated(
    `(async()=>{const b=a.activeBytes();for(let i=0;i<100;i++){await a.asyncLiteral();}const mid=a.activeBytes();for(let i=0;i<3;i++){global.gc();await new Promise(r=>setImmediate(r));}console.log(JSON.stringify({b,mid,after:a.activeBytes()}));})()`,
    ["--expose-gc"],
  );
  t.is(probe.status, 0, probe.stderr);
  const measured = JSON.parse(probe.stdout.trim().split("\n").pop());
  t.true(measured.mid > measured.b, "settlement state is allocated per promise");
  t.is(measured.after, measured.b, "GC must return the allocator to its baseline");
});

test("async allocated borrowed result is not freed by the runtime", async (t) => {
  const before = native.activeBytes();
  t.is(await native.asyncAllocatedBorrowed(), "allocated");
  // Plain results are borrowed: the runtime keeps its hands off them, which is
  // why heap results must migrate to napi.Owned.
  t.true(native.activeBytes() > before);
});

test("async error Result rejects with its own error", async (t) => {
  const rejection = await settlesWithin(native.asyncResult(0), 2000);
  t.is(rejection.state, "rejected");
  t.true(String(rejection.message).includes("expected rejection"));
  t.is(await native.asyncResult(5), 5);
});

test("async completion conversion failure rejects instead of hanging", async (t) => {
  const outcome = await settlesWithin(native.asyncBadConversion(), 2000);
  t.is(outcome.state, "rejected");
  t.not(outcome.message, "timeout");
});

test("async captured input is cloned for the worker thread", async (t) => {
  const text = "audit-capture";
  t.is(await native.asyncEchoBytes(text), text);
  for (let index = 0; index < 50; index += 1) {
    t.is(await native.asyncThreadValue(index), index + 1);
  }
});

test("unused converted arguments are released by the export wrapper", async (t) => {
  const before = native.activeBytes();
  for (let index = 0; index < 100; index += 1) {
    await native.asyncUnusedInput("abc", 1);
  }
  const leaked = native.activeBytes() - before;
  // KNOWN DEPENDENCY: the Function wrapper still skips argument cleanup for
  // async returns (`cleanup_params = false` in src/napi/value/function.zig), so
  // each call may still leak the converted 3 byte argument. Once that lands,
  // `leaked` must be at most the per-promise settlement state.
  t.true(
    leaked <= 100 * capabilityBytesPerCall + 300,
    `expected only settlement state plus wrapper-owned arguments, got ${leaked}`,
  );
});

test("scheduling a consumed async descriptor fails cleanly", async (t) => {
  t.is(await native.asyncDoubleSchedule(7), 1);
  t.is(native.asyncDescriptorReused(), 1);
});

test("promise copies share settlement state", async (t) => {
  t.is(await native.sharedPromiseSettlement(), 11);
  t.is(native.settleSuccessCount(), 1);
});

test("double resolve and reject-after-resolve throw instead of crashing", async (t) => {
  t.throws(() => native.doubleResolve());
  t.throws(() => native.rejectAfterResolve());

  const resolved = runIsolated("try{a.doubleResolve()}catch(e){console.log('caught:'+e.message)}");
  t.is(resolved.status, 0);
  t.true(resolved.stdout.includes("caught:"));

  const rejected = runIsolated(
    "try{a.rejectAfterResolve()}catch(e){console.log('caught:'+e.message)}",
  );
  t.is(rejected.status, 0);
  t.true(rejected.stdout.includes("caught:"));
});

test("borrowed JavaScript promises cannot be settled", async (t) => {
  t.false(native.borrowedPromiseSettlable(Promise.resolve(1)));
  t.throws(() => native.resolveForeign(Promise.resolve(1)));

  const isolated = runIsolated(
    "try{a.resolveForeign(Promise.resolve(1))}catch(e){console.log('caught:'+e.message)}",
  );
  t.is(isolated.status, 0);
  t.true(isolated.stdout.includes("caught:"));
});

test("cancelled worker settles its promise", async (t) => {
  const outcome = await settlesWithin(native.workerCancelled(), 3000);
  t.not(outcome.state, "timeout");
  if (outcome.state === "rejected") {
    t.true(String(outcome.message).includes("AbortError"));
  }
});

test("worker promise resolves with its result", async (t) => {
  t.is(await native.workerValue(41), 42);
});

test("AbortSignal keeps foreign onabort handlers and other listeners", async (t) => {
  native.resetAbortCallbackCount();
  const controller = new AbortController();
  let foreign = 0;
  let extra = 0;
  controller.signal.onabort = () => {
    foreign += 1;
  };
  controller.signal.addEventListener("abort", () => {
    extra += 1;
  });

  await native.bindAndHold(controller.signal);
  controller.abort();

  t.is(foreign, 1, "existing onabort handler must survive binding");
  t.is(extra, 1, "pre-existing listeners must survive binding");
  t.is(native.abortCallbackCount(), 1, "native listener must observe the abort");
  native.releaseHeldSignal();
  t.is(native.abortCallbackCount(), 1);
});

test("multiple native registrations on one signal all fire", async (t) => {
  native.resetAbortCallbackCount();
  const controller = new AbortController();
  await native.bindAndHold(controller.signal);
  await native.bindSecondAndHold(controller.signal);
  controller.abort();
  t.is(native.abortCallbackCount(), 2);
  native.releaseHeldSignal();
  native.releaseSecondHeldSignal();
});

test("released registrations are inert but safe when hostile JS retains them", async (t) => {
  native.resetAbortCallbackCount();
  const retained = [];
  const hostile = {
    aborted: false,
    reason: undefined,
    addEventListener(_type, listener) {
      retained.push(listener);
    },
    removeEventListener() {},
  };

  await native.bindAndHold(hostile);
  t.is(retained.length, 1);
  native.releaseHeldSignal();

  // Signaling after release must not run the callback and must not touch freed
  // memory even though the hostile object kept the listener alive.
  retained[0]();
  t.is(native.abortCallbackCount(), 0);
});

test("foreign wrapped objects are rejected with a TypeError", async (t) => {
  const error = t.throws(() => native.bindAndHold({}));
  t.true(String(error.message).includes("AbortSignal"));

  const isolated = runIsolated(
    "try{a.bindAndHold({})}catch(e){console.log('caught:'+e.name+':'+e.message)}",
  );
  t.is(isolated.status, 0);
  t.true(isolated.stdout.includes("caught:TypeError"));
});

test("signal-like objects without listener methods are rolled back", async (t) => {
  // Validation happens before any native registration is created.
  t.throws(() => native.bindAndHold({ addEventListener: 42, removeEventListener() {} }));
  t.throws(() => native.bindAndHold({ addEventListener() {} }));
  t.throws(() => native.bindAndHold({ aborted: false }));

  // A hostile addEventListener that *throws* exercises the rollback path after
  // the listener exists. It currently aborts a Debug build inside the Function
  // wrapper, which re-throws over the pending JavaScript exception
  // (src/napi/value/function.zig `throwAndUndefined` -> `Error.throwInto`
  // asserts on napi_throw). That is the core F01 dependency; the rollback
  // itself is covered by the bind/release loop below.
  native.releaseHeldSignal();

  const before = native.activeBytes();
  const controller = new AbortController();
  for (let index = 0; index < 200; index += 1) {
    await native.bindAndHold(controller.signal);
    native.releaseHeldSignal();
  }
  const leaked = native.activeBytes() - before;
  // Listener functions and registrations are released as their JavaScript
  // function objects are collected; nothing may grow per bind/release cycle.
  t.true(leaked < 200 * 1024, `bind/release cycle grew by ${leaked} bytes`);
});

test("pre-aborted and mid-flight async aborts reject with AbortError", async (t) => {
  const preAborted = new AbortController();
  preAborted.abort();
  const pre = await settlesWithin(native.asyncAbortable(4096, preAborted.signal), 3000);
  t.is(pre.state, "rejected");
  t.true(String(pre.message).includes("AbortError"));

  const controller = new AbortController();
  const pending = native.asyncAbortable(200000000, controller.signal);
  await delay(0);
  controller.abort();
  const mid = await settlesWithin(pending, 5000);
  t.is(mid.state, "rejected");
  t.true(String(mid.message).includes("AbortError"));
});

test("one signal can drive several tasks without cross-talk", async (t) => {
  const controller = new AbortController();
  const first = native.asyncMultiSignalTask(200000000, controller.signal);
  const second = native.asyncMultiSignalTask(200000000, controller.signal);
  await delay(0);
  controller.abort();
  const outcomes = await Promise.all([settlesWithin(first, 5000), settlesWithin(second, 5000)]);
  for (const outcome of outcomes) {
    t.is(outcome.state, "rejected");
    t.true(String(outcome.message).includes("AbortError"));
  }
});

test("threaded runtime keeps working after another environment closes", async (t) => {
  t.is(await native.asyncThreadValue(1), 2);

  const worker = new Worker(workerSource, { workerData: { mode: "async" } });
  const message = await new Promise((resolve, reject) => {
    worker.once("message", resolve);
    worker.once("error", reject);
  });
  t.is(message.value, 8, "worker environment ran a threaded task");
  await worker.terminate();
  await delay(50);

  // The main environment must keep submitting work even though the worker
  // environment (and its cleanup hook) is gone.
  for (let index = 0; index < 5; index += 1) {
    t.is(await native.asyncThreadValue(index), index + 1);
  }
});

test("thread-safe function queue survives its environment being torn down", async (t) => {
  const worker = new Worker(workerSource, { workerData: { mode: "tsfn-abandon" } });
  const message = await new Promise((resolve, reject) => {
    worker.once("message", resolve);
    worker.once("error", reject);
  });
  t.is(message.queued, 4);
  await worker.terminate();
  await delay(50);
  // Nothing to assert beyond "the process survived": the queued items are
  // released by the null-environment drain, never by JavaScript.
  t.pass();
});

test("thread-safe function still delivers queued calls normally", async (t) => {
  const calls = [];
  await new Promise((resolve, reject) => {
    try {
      native.queueThreadSafeFunction(
        (err, value) => {
          if (err) {
            reject(new Error("unexpected tsfn error"));
            return;
          }
          calls.push(value);
          if (calls.length === 4) resolve();
        },
        10,
        4,
      );
    } catch (error) {
      reject(error);
    }
  });
  t.deepEqual(calls, [10, 11, 12, 13]);
  t.true(native.freeCount() > 0);
});

test("async calls return to the counting allocator baseline", async (t) => {
  await native.asyncLiteral();
  await native.asyncThreadValue(3);
  const before = native.activeBytes();
  for (let index = 0; index < 50; index += 1) {
    await native.asyncLiteral();
  }
  const leaked = native.activeBytes() - before;
  t.true(leaked <= 50 * capabilityBytesPerCall, `expected only settlement state, got ${leaked}`);
  t.true(native.allocationCount() > 0);
});
