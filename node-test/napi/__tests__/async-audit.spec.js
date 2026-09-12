// Regression spec for the async/abort/TSFN/runtime audit findings
// (F04 async ownership, F08 AbortSignal, F09 async cancellation,
// F10 TSFN shutdown, F11 promise settlement, F14 runtime environments).
//
// Tests that need a child process or a second environment are marked
// `nativeOnlyTest`: under the WASI/emnapi build those facilities are not part of
// the runtime, and pretending to cover them there would be misleading.
const path = require("path");
const test = require("ava");

const loaderPath = path.join(__dirname, "..", "..", "load-addon.js");
const native = require(loaderPath)("async_audit");
const workerSource = path.join(__dirname, "async-audit-worker.js");

// `require("node:...")` prefixes are not available on every Node version this
// suite supports (Node 12), so the built-in modules are required lazily by name
// and only where they are actually used.
function childProcess() {
  return require("child_process");
}

function workerThreads() {
  return require("worker_threads");
}

const isWasi =
  process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";
const nativeOnlyTest = isWasi ? test.skip : test;
const abortTest = typeof AbortController === "undefined" ? test.skip : test;

function runIsolated(body, extraArgs = [], timeoutMs = 5000) {
  return childProcess().spawnSync(
    process.execPath,
    [...extraArgs, "-e", `const a=require(${JSON.stringify(loaderPath)})("async_audit");${body}`],
    { encoding: "utf8", timeout: timeoutMs },
  );
}

// A settled promise keeps its settlement state alive until the JavaScript
// promise object is collected (`Capability` in src/napi/value/promise.zig is
// owned by the promise object's wrap finalizer). The size is queried from the
// native side instead of being hardcoded; the "settlement state is reclaimed"
// test proves the memory is not leaked.
function settlementStateSize() {
  return native.promiseSettlementStateSize();
}

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
      return {
        state: "rejected",
        message: error && error.message ? error.message : String(error),
        error,
      };
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
  t.true(leaked <= 100 * settlementStateSize(), `expected only settlement state, got ${leaked}`);
});

nativeOnlyTest("settlement state is reclaimed once the JS promises are collected", (t) => {
  const probe = runIsolated(
    `(async()=>{const b=a.activeBytes();for(let i=0;i<100;i++){await a.asyncLiteral();}const mid=a.activeBytes();for(let i=0;i<3;i++){global.gc();await new Promise(r=>setImmediate(r));}console.log(JSON.stringify({b,mid,after:a.activeBytes()}));})()`,
    ["--expose-gc"],
  );
  t.is(probe.status, 0, probe.stderr);
  const measured = JSON.parse(probe.stdout.trim().split("\n").pop());
  t.true(measured.mid > measured.b, "settlement state is allocated per promise");
  t.is(measured.after, measured.b, "GC must return the allocator to its baseline");
});

test("owned results are disposed after conversion", async (t) => {
  const before = native.activeBytes();
  t.is(await native.asyncOwnedResult(), "owned");
  // The runtime disposed the Owned payload; only the promise settlement state
  // (reclaimed by GC) remains.
  const leaked = native.activeBytes() - before;
  t.true(leaked <= settlementStateSize(), `owned result leaked ${leaked} bytes`);
});

test("borrowed results stay owned by the runner until it releases them", async (t) => {
  const before = native.activeBytes();
  t.is(await native.asyncAllocatedBorrowed(), "allocated");
  // Plain results are borrowed: the runtime keeps its hands off them, which is
  // why heap results must migrate to napi.Owned.
  t.true(native.activeBytes() > before, "borrowed result stays alive");
  native.releaseBorrowedResult();
  const leaked = native.activeBytes() - before;
  t.true(
    leaked <= settlementStateSize(),
    `borrowed result was not released by its owner: ${leaked} bytes`,
  );
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

test("error text created on the task thread survives the trip back", async (t) => {
  // The runner formats its message into a stack buffer on the worker thread: it
  // is only readable because the operation snapshots it before queuing the
  // completion.
  const async = await settlesWithin(native.asyncBackgroundError(), 3000);
  t.is(async.state, "rejected");
  t.true(String(async.message).includes("background failure 7"), `got ${async.message}`);

  const worker = await settlesWithin(native.workerFailure(1), 3000);
  t.is(worker.state, "rejected");
  t.true(String(worker.message).includes("worker failure 3"), `got ${worker.message}`);
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
  // The wrapper releases every converted argument of an async call; only the
  // per-promise settlement state (GC-timed) may remain.
  const leaked = native.activeBytes() - before;
  t.true(leaked <= 100 * settlementStateSize(), `expected only settlement state, got ${leaked}`);
});

test("queued events own their payload data", async (t) => {
  const queued = [];
  const count = await native.asyncSliceEvents(6, (event) => queued.push(event.text));
  t.is(count, 6);
  // The producer overwrites its temporary buffer right after each emit: a
  // shallow copy would deliver the overwritten text.
  t.deepEqual(queued, ["event-0", "event-1", "event-2", "event-3", "event-4", "event-5"]);

  const single = [];
  t.is(await native.asyncSliceEventsSingle(3, (event) => single.push(event.text)), 3);
  t.deepEqual(single, ["event-0", "event-1", "event-2"]);
});

test("a listener that throws a primitive rejects with exactly that value", async (t) => {
  // `napi_create_reference` only accepts objects below N-API 10: the runtime
  // roots the thrown value in a holder object instead, so primitives keep their
  // identity and the task can never resolve silently.
  const cases = [
    ["number", 42, (value) => value === 42],
    ["string", "boom", (value) => value === "boom"],
    ["null", null, (value) => value === null],
    ["undefined", undefined, (value) => value === undefined],
  ];
  for (const [name, thrown, matches] of cases) {
    const outcome = await settlesWithin(
      native.asyncThrowingEvents(2, () => {
        throw thrown;
      }),
      3000,
    );
    t.is(outcome.state, "rejected", `${name} must reject`);
    t.true(matches(outcome.error), `${name} must reject with its own value`);
  }
});

test("a synchronous listener failure follows the same path", async (t) => {
  const boom = { marker: "single-runtime" };
  const outcome = await settlesWithin(
    native.asyncThrowingEventsSingle(2, () => {
      throw boom;
    }),
    3000,
  );
  t.is(outcome.state, "rejected");
  t.is(outcome.error, boom);
});

test("a listener exception is not overridden by a runner failure", async (t) => {
  const boom = new Error("listener wins");
  const outcome = await settlesWithin(
    native.asyncRunnerFailureAfterEvent(() => {
      throw boom;
    }),
    3000,
  );
  t.is(outcome.state, "rejected");
  t.is(outcome.error, boom, "the listener's own exception has priority");
});

abortTest("a hostile removeEventListener settles the promise instead of hanging it", (t) => {
  // The cleanup runs after the settlement reason is fixed: an exception thrown
  // by `removeEventListener` must neither leave the promise pending nor escape
  // as an uncaught Node-API callback exception.
  const probe = runIsolated(
    `const signal = { aborted: false, addEventListener() {}, removeEventListener() { const e = new Error("cleanup boom"); e.marker = "cleanup"; throw e; } };
     (async () => {
       const outcome = await a.asyncAbortable(4096, signal).then(
         (value) => ({ state: "resolved", value }),
         (error) => ({ state: "rejected", marker: error && error.marker, message: error && error.message }),
       );
       console.log(JSON.stringify(outcome));
     })();`,
    ["--force-node-api-uncaught-exceptions-policy=true"],
  );
  t.is(probe.status, 0, probe.stderr);
  const outcome = JSON.parse(probe.stdout.trim().split("\n").pop());
  t.is(outcome.state, "rejected", "a failed cleanup must not resolve the promise");
  t.is(outcome.marker, "cleanup");
  t.false(
    /Uncaught Node-API callback exception/.test(probe.stderr),
    `cleanup exceptions must not escape: ${probe.stderr}`,
  );
});

test("a missing optional listener behaves like an explicit undefined one", async (t) => {
  // The generated wrapper passes the absent listener as a null handle (a nested
  // optional `Some(null)`); it must not reach `napi_typeof`.
  t.is(await native.asyncSliceEvents(1), 1);
  t.is(await native.asyncSliceEvents(1, undefined), 1);
  t.is(await native.asyncSliceEvents(1, null), 1);
  // A non-callable listener is still rejected (the missing/undefined/null
  // spellings above are the ones that mean "no listener").
  t.throws(() => native.asyncSliceEvents(1, 42));
});

test("events without a listener are neither cloned nor queued", async (t) => {
  const before = native.allocationCount();
  const beforeBytes = native.activeBytes();
  // Explicit `undefined` is the same as passing nothing: nobody can observe the
  // events, so the producer must not pay for them (H10).
  t.is(await native.asyncSliceEvents(3000, undefined), 3000);
  t.is(await native.asyncSliceEventsNoListener(3000), 3000);
  const allocationDelta = native.allocationCount() - before;
  t.true(allocationDelta < 64, `expected no per-event allocations, got ${allocationDelta}`);
  const byteDelta = native.activeBytes() - beforeBytes;
  t.true(byteDelta < 64 * 1024, `no per-event payload may be retained: ${byteDelta} bytes`);
});

test("an omitted listener with many events allocates almost nothing", async (t) => {
  const before = native.allocationCount();
  t.is(await native.asyncSliceEventsNoListener(10000), 10000);
  t.is(await native.asyncSliceEvents(10000, undefined), 10000);
  // 20000 events without a listener: the whole run may only cost the operation
  // and its completion (the leader's hidden-risk fixture allows 128 calls for
  // half that many events).
  const allocationDelta = native.allocationCount() - before;
  t.true(allocationDelta < 128, `unobserved events allocated ${allocationDelta} times`);
});

nativeOnlyTest("thousands of threaded tasks return to the allocation baseline", (t) => {
  // Every threaded operation owns two producer futures (`std.Io.concurrent`),
  // and each of them is freed by exactly one `await`/`cancel`. A per-operation
  // leak of even a few dozen bytes shows up here; a crash-only regression test
  // would not see it.
  const probe = runIsolated(
    `(async()=>{
      const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(r=>setImmediate(r));}};
      for(let i=0;i<50;i++){await a.asyncTinyThreadValue(i);}
      await collect();
      const before=a.activeBytes();
      for(let i=0;i<2000;i++){await a.asyncTinyThreadValue(i);}
      await collect();
      console.log(JSON.stringify({before,after:a.activeBytes()}));
    })().catch((error)=>{console.error(error);process.exitCode=1});`,
    ["--expose-gc"],
    60000,
  );
  t.is(probe.status, 0, probe.stderr);
  const measured = JSON.parse(probe.stdout.trim().split("\n").pop());
  t.is(measured.after, measured.before, `2000 threaded tasks leaked ${measured.after - measured.before} bytes`);
});

test("the event queue is bounded and still delivers every event in order", async (t) => {
  const limit = native.eventQueueLimit();
  t.true(limit > 0 && limit < 100000, `unexpected queue limit ${limit}`);

  native.resetEventQueueHighWater();
  const total = limit * 20;
  const seen = [];
  const pending = native.asyncSliceEvents(total, (event) => {
    seen.push(event.index);
  });
  // Block the JavaScript thread so nothing drains while the producer fills the
  // queue: it has to wait for capacity instead of allocating `total` payloads.
  const until = Date.now() + 300;
  while (Date.now() < until) {
    // busy wait
  }
  t.is(native.eventQueueHighWater(), limit, "the producer must stop at the queue limit");
  t.is(await pending, total);
  t.is(seen.length, total, "no event may be lost");
  // FIFO: the listener observes the producer's order, so a listener exception
  // still precedes the settlement.
  for (let index = 0; index < total; index += 1) {
    if (seen[index] !== index) {
      t.fail(`event ${index} arrived as ${seen[index]}`);
      break;
    }
  }
  t.is(native.eventQueueHighWater(), limit, "the bound holds for the whole run");
});

abortTest("cancelling releases a producer that waits for queue capacity", async (t) => {
  const controller = new AbortController();
  const limit = native.eventQueueLimit();
  native.resetEventQueueHighWater();
  let delivered = 0;
  const pending = native.asyncAbortableSliceEvents(1000000, controller.signal, () => {
    delivered += 1;
  });
  // Make the JavaScript side slow enough that the producer fills the queue and
  // blocks, then abort: the cancellation must wake it even though the
  // JavaScript thread cannot drain the queue it is waiting on.
  const until = Date.now() + 50;
  while (Date.now() < until) {
    // busy wait
  }
  t.is(native.eventQueueHighWater(), limit, "the producer must have been blocked on a full queue");
  controller.abort();
  const outcome = await settlesWithin(pending, 5000);
  t.is(outcome.state, "rejected");
  t.true(String(outcome.message).includes("AbortError"), `got ${outcome.message}`);
  t.true(delivered < 1000000, `the producer stopped instead of draining the queue (${delivered})`);
});

nativeOnlyTest("queued events and a blocked producer release everything at worker shutdown", async (t) => {
  // Ten environments, each with a producer that filled its bounded queue while
  // the environment's thread was blocked in the listener. Terminating them
  // closes the queue under a blocked producer, runs the finalizer before the
  // null-environment drain, and must leave the counting allocator at its
  // baseline - without crashing or hanging.
  await native.asyncSliceEvents(1, () => {});
  const probe = runIsolated(
    `(async()=>{
      const {Worker}=require("worker_threads");
      const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(r=>setImmediate(r));}};
      await a.asyncSliceEvents(1,()=>{});
      await collect();
      const baseline=a.activeBytes();
      for(let i=0;i<10;i++){
        const worker=new Worker(${JSON.stringify(
          `const {parentPort}=require('worker_threads');
           const a=require(${JSON.stringify(loaderPath)})("async_audit");
           a.asyncSliceEvents(100000,(event)=>{if(event.index===0){const until=Date.now()+500;while(Date.now()<until){}};}).catch(()=>{});
           parentPort.postMessage("started");`,
        )},{eval:true});
        await new Promise((resolve,reject)=>{worker.once("message",resolve);worker.once("error",reject);});
        await new Promise((r)=>setTimeout(r,25));
        await worker.terminate();
      }
      await new Promise((r)=>setTimeout(r,1000));
      await collect();
      console.log(JSON.stringify({baseline,after:a.activeBytes()}));
    })().catch((error)=>{console.error(error);process.exitCode=1});`,
    ["--expose-gc"],
    60000,
  );
  t.is(probe.status, 0, probe.stderr);
  const measured = JSON.parse(probe.stdout.trim().split("\n").pop());
  t.is(measured.after, measured.baseline, `shutdown leaked ${measured.after - measured.baseline} bytes`);
});

test("a throwing event listener rejects the task with the original exception", async (t) => {
  const boom = new Error("listener boom");
  boom.marker = "original";

  const outcome = await settlesWithin(
    native.asyncThrowingEvents(2, () => {
      throw boom;
    }),
    3000,
  );
  t.is(outcome.state, "rejected");
  t.is(outcome.error, boom, "rejection reason must be the listener's own exception object");

  // Same listener, but the completion conversion also fails: the original
  // exception still wins over the synthesized conversion error.
  const withConversionFailure = await settlesWithin(
    native.asyncPendingExceptionCompletion(() => {
      throw boom;
    }),
    3000,
  );
  t.is(withConversionFailure.state, "rejected");
  t.is(withConversionFailure.error, boom);
});

test("scheduling a consumed async descriptor fails cleanly", async (t) => {
  t.is(await native.asyncDoubleSchedule(7), 1);
  t.is(native.asyncDescriptorReused(), 1);
});

test("promise copies share settlement state", async (t) => {
  t.is(await native.sharedPromiseSettlement(), 11);
  t.is(native.settleSuccessCount(), 1);
});

test("promise status describes the winning settlement for every alias", async (t) => {
  const rejected = native.rejectedPromiseStatus();
  // 2 = rejected: a rejected promise must not report "resolved".
  t.is(native.promiseStatusAfterReject(), 2);
  await t.throwsAsync(rejected);

  const resolved = native.resolvedPromiseStatus();
  t.is(native.promiseStatusAfterResolve(), 1);
  t.is(await resolved, 3);
});

test("double resolve and reject-after-resolve throw instead of crashing", async (t) => {
  t.throws(() => native.doubleResolve());
  t.throws(() => native.rejectAfterResolve());
});

nativeOnlyTest("the former crashes stay controlled in a fresh process", (t) => {
  const resolved = runIsolated("try{a.doubleResolve()}catch(e){console.log('caught:'+e.message)}");
  t.is(resolved.status, 0);
  t.true(resolved.stdout.includes("caught:"));

  const rejected = runIsolated(
    "try{a.rejectAfterResolve()}catch(e){console.log('caught:'+e.message)}",
  );
  t.is(rejected.status, 0);
  t.true(rejected.stdout.includes("caught:"));

  const foreign = runIsolated(
    "try{a.resolveForeign(Promise.resolve(1))}catch(e){console.log('caught:'+e.message)}",
  );
  t.is(foreign.status, 0);
  t.true(foreign.stdout.includes("caught:"));

  const wrapped = runIsolated(
    "try{a.bindAndHold({})}catch(e){console.log('caught:'+e.name+':'+e.message)}",
  );
  t.is(wrapped.status, 0);
  t.true(wrapped.stdout.includes("caught:TypeError"));
});

test("borrowed JavaScript promises cannot be settled", async (t) => {
  t.false(native.borrowedPromiseSettlable(Promise.resolve(1)));
  t.throws(() => native.resolveForeign(Promise.resolve(1)));
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

abortTest("AbortSignal keeps foreign onabort handlers and other listeners", async (t) => {
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

abortTest("multiple native registrations on one signal all fire", async (t) => {
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
});

test("signal-like objects without listener methods are rolled back", async (t) => {
  // Validation happens before any native registration is created.
  t.throws(() => native.bindAndHold({ addEventListener: 42, removeEventListener() {} }));
  t.throws(() => native.bindAndHold({ addEventListener() {} }));
  t.throws(() => native.bindAndHold({ aborted: false }));

  // A hostile addEventListener that *throws* exercises the rollback path after
  // the listener exists; the wrapper's error path keeps the original exception
  // (see the conversion repair) instead of aborting a Debug build.
  const hostile = {
    aborted: false,
    addEventListener() {
      const error = new Error("refused");
      error.marker = "refused";
      throw error;
    },
    removeEventListener() {},
  };
  for (let index = 0; index < 50; index += 1) {
    const error = t.throws(() => native.bindAndHold(hostile));
    t.is(error.marker, "refused");
  }
  native.releaseHeldSignal();

  if (typeof AbortController === "undefined") return;
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

abortTest("pre-aborted and mid-flight async aborts reject with AbortError", async (t) => {
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

abortTest("one signal can drive several tasks without cross-talk", async (t) => {
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

nativeOnlyTest("threaded runtime keeps working after another environment closes", async (t) => {
  t.is(await native.asyncThreadValue(1), 2);

  const { Worker } = workerThreads();
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

nativeOnlyTest("runtime survives repeated worker environments starting and dying", async (t) => {
  const { Worker } = workerThreads();

  for (let round = 0; round < 5; round += 1) {
    const workers = [];
    for (let index = 0; index < 3; index += 1) {
      workers.push(new Worker(workerSource, { workerData: { mode: "async" } }));
    }
    const messages = await Promise.all(
      workers.map(
        (worker) =>
          new Promise((resolve, reject) => {
            worker.once("message", resolve);
            worker.once("error", reject);
          }),
      ),
    );
    t.is(messages.length, 3);

    // Terminating a worker stops its environment while its runtime operations
    // may still be draining; that must never release the runtime the main
    // environment keeps using (and never joins the runtime from one of its own
    // pool workers).
    for (const worker of workers) {
      await worker.terminate();
    }
    t.is(await native.asyncThreadValue(round), round + 1);
  }
});

nativeOnlyTest("a runtime released from its own pool worker does not join itself", async (t) => {
  // The worker environment is the only owner of the runtime in this child
  // process, and its task is still in flight when the environment goes away, so
  // the release happens on a runtime pool worker. A self join would hang here.
  //
  // The parent stays alive for the whole window in which the abandoned producer
  // is still running: exiting as soon as the worker is terminated would hide a
  // use-after-free inside `runTask` (H01).
  const probe = runIsolated(
    `(async()=>{
      const { Worker } = require("worker_threads");
      const worker = new Worker(${JSON.stringify(workerSource)}, { workerData: { mode: "async-slow", loader: ${JSON.stringify(loaderPath)} } });
      await new Promise((resolve, reject) => { worker.once("message", resolve); worker.once("error", reject); });
      await worker.terminate();
      await new Promise((resolve) => setTimeout(resolve, 2000));
      console.log("survived");
    })().catch((error) => { console.log("error:" + error.message); })`,
    ["--force-node-api-uncaught-exceptions-policy=true"],
  );
  t.is(probe.status, 0, probe.stderr);
  t.true(probe.stdout.includes("survived"), `unexpected output: ${probe.stdout} ${probe.stderr}`);
  t.false(/uncaught/i.test(probe.stderr), `no exception may escape teardown: ${probe.stderr}`);
});

nativeOnlyTest("an abandoned producer finishes after its environment is torn down", async (t) => {
  const { Worker } = workerThreads();
  const before = native.completedThreadedOperations();
  const worker = new Worker(workerSource, { workerData: { mode: "async-counted-slow" } });
  await new Promise((resolve, reject) => {
    worker.once("message", resolve);
    worker.once("error", reject);
  });
  await worker.terminate();
  // The addon's state is process wide: the counter proves the task ran to its
  // end (reading its own captured input) after the environment was destroyed.
  await delay(2000);
  const after = native.completedThreadedOperations();
  t.true(after > before, `abandoned producer did not finish (${before} -> ${after})`);
  // ... and the runtime is still usable by the surviving environment.
  t.is(await native.asyncThreadValue(3), 4);
});

nativeOnlyTest("queued events survive the environment finalizer and its null-environment drain", async (t) => {
  const { Worker } = workerThreads();
  for (let round = 0; round < 2; round += 1) {
    const worker = new Worker(workerSource, { workerData: { mode: "events-abandoned" } });
    await new Promise((resolve, reject) => {
      worker.once("message", resolve);
      worker.once("error", reject);
    });
    // Terminate while the worker's listener is blocked and events are queued:
    // the finalizer runs first, the queue is drained afterwards with a null
    // environment, and the records must still be usable then. The producer is
    // already done, so only the records' own references keep the operation
    // alive at that point.
    await delay(150);
    await worker.terminate();
    await delay(100);
  }
  await delay(1200);
  t.is(await native.asyncThreadValue(2), 3);
});

abortTest("tearing down an environment with an abortable task does not free it early", async (t) => {
  const { Worker } = workerThreads();
  for (let round = 0; round < 3; round += 1) {
    const worker = new Worker(workerSource, { workerData: { mode: "async-abandoned-abortable" } });
    await new Promise((resolve, reject) => {
      worker.once("message", resolve);
      worker.once("error", reject);
    });
    await worker.terminate();
  }
  // The operation, its controller and its abort registration must all outlive
  // the environment that started them (H01: three of three crashed before).
  await delay(1500);
  t.is(await native.asyncThreadValue(1), 2);
});

nativeOnlyTest("thread-safe function queue survives its environment being torn down", async (t) => {
  const { Worker } = workerThreads();
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
  t.true(leaked <= 50 * settlementStateSize(), `expected only settlement state, got ${leaked}`);
  t.true(native.allocationCount() > 0);
});
