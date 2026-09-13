// Child harness for `wasm-async-lifecycle.spec.js`.
//
// Every scenario that can park a thread runs here rather than in the test
// worker: a hang inside wasm blocks the very event loop that would run an
// in-process watchdog, so the *parent* enforces the timeout by killing this
// process. The scenario prints one `RESULT {...}` line; a failure prints a
// stack and exits non-zero.
//
// usage: node wasm-async-child.cjs <scenario> <wasm file> <threaded|threadless>
const fs = require("fs");
const path = require("path");
const { WASI } = require("node:wasi");

const runtime = require("@napi-rs/wasm-runtime");

const scenario = process.argv[2];
const wasmPath = process.argv[3];
const threaded = process.argv[4] === "threaded";

function instantiate() {
  const rootDir = path.parse(process.cwd()).root;
  // emnapi registers a `beforeExit` auto-destroy listener per context that
  // `suppressDestroy()` only neutralizes; a process running several instances
  // would pile them up.
  const beforeExit = process.listeners("beforeExit");
  const context = runtime.createContext({ autoDestroy: false });
  context.suppressDestroy();
  for (const listener of process.listeners("beforeExit")) {
    if (!beforeExit.includes(listener)) process.removeListener("beforeExit", listener);
  }

  const memory = new WebAssembly.Memory({
    initial: 4096,
    maximum: 65536,
    shared: threaded,
  });
  const options = {
    context,
    asyncWorkPoolSize: threaded ? 4 : 0,
    plugins: [runtime.emnapiAsyncWorkPlugin, runtime.emnapiTSFNPlugin],
    wasi: new WASI({
      version: "preview1",
      env: process.env,
      preopens: { [rootDir]: rootDir },
    }),
    overwriteImports(importObject) {
      importObject.env = {
        ...importObject.env,
        ...importObject.napi,
        ...importObject.emnapi,
        memory,
      };
      return importObject;
    },
  };
  if (threaded) {
    const { Worker } = require("node:worker_threads");
    options.reuseWorker = true;
    options.onCreateWorker = () => {
      const worker = new Worker(path.join(__dirname, "wasm-async-worker.mjs"), {
        env: process.env,
      });
      worker.onmessage = ({ data }) => {
        runtime.createOnMessage(fs)(data);
      };
      worker.unref();
      return worker;
    };
  }
  const { instance, napiModule } = runtime.instantiateNapiModuleSync(
    fs.readFileSync(wasmPath),
    options,
  );
  return {
    api: napiModule.exports,
    destroy: () => {
      // Mirrors the loader's disposal: the barrier first, then the context.
      const result = context.destroy();
      if (result && typeof result.then === "function") return result;
      return undefined;
    },
    memory,
    pending: instance.exports.napi_wasm_env_cleanup_pending,
    prepare: instance.exports.napi_prepare_wasm_env_cleanup,
  };
}

function outcome(promise) {
  return promise.then(
    (value) => ({ state: "resolved", value }),
    (error) => ({
      state: "rejected",
      code: error && error.code,
      message: error && error.message,
    }),
  );
}

async function drain(instance, turns = 256) {
  for (let turn = 0; turn < turns; turn += 1) {
    await new Promise((resolve) => setImmediate(resolve));
    if (!instance.pending()) return turn + 1;
  }
  return -1;
}

/// Block this thread without letting any macrotask run: the JS side is inside
/// wasm when this returns, which is exactly how a worker gets ahead of the
/// host's completion callback.
function blockHost(ms) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    // busy wait
  }
}

const scenarios = {
  /// Cancellation has to be observable without a timer: a timer only fires
  /// where the task body can run concurrently with it, and the threadless host
  /// runs that body itself. Driven from the task's own progress callback, the
  /// abort reaches the producer on every flavor, and a second task sharing the
  /// signal sees it too - whether it is already running (worker flavor) or
  /// starts after the first one returned (threadless).
  abort_from_callback: async (instance) => {
    const slow = Number(process.env.WASM_ASYNC_SLOW_TASK || "200000000");
    const total = Number(process.env.WASM_ASYNC_PER_TASK || "1000000");
    const controller = new AbortController();
    let delivered = 0;
    const first = outcome(
      instance.api.asyncAbortableSliceEvents(total, controller.signal, () => {
        delivered += 1;
        if (delivered === 1) controller.abort();
      }),
    );
    const second = outcome(instance.api.asyncMultiSignalTask(slow, controller.signal));
    const settled = await Promise.all([first, second]);
    // The pre-aborted shape, which must reject on every flavor: the signal is
    // already aborted when the task is submitted.
    const preAborted = new AbortController();
    preAborted.abort();
    const pre = await outcome(instance.api.asyncAbortable(4096, preAborted.signal));
    return { delivered, pre, settled, total };
  },

  /// The barrier must not settle ahead of progress the task already queued: a
  /// listener that throws has to reject the promise with its own value, and
  /// every queued event still has to be delivered.
  ///
  /// Construction: the first event's listener holds the JavaScript turn long
  /// enough for the worker to finish, then raises the barrier *while* the rest
  /// of the progress is still queued. The barrier has to queue the completion
  /// behind that progress instead of settling early.
  throw_after_finish: async (instance, { threaded: workerFlavor }) => {
    if (!workerFlavor) {
      // Threadless events are delivered inline, so a listener that raises the
      // barrier always does it while the task is still running: the barrier
      // cancels it, and the cancellation is the documented outcome (covered by
      // the cancellation scenario).
      return { skipped: "threadless" };
    }
    const primed = await instance.api.asyncThreadValue(1);
    const total = 3;
    // Both shapes: a primitive is the one an implementation that re-creates the
    // reason instead of keeping the thrown value gets wrong most quietly.
    const boom =
      process.env.WASM_ASYNC_THROWN === "primitive" ? "queued-listener-throw" : { marker: "queued-listener-throw" };
    const seen = [];
    let barrierPending = -1;
    let reason;
    await instance.api
      .asyncSliceEvents(total, (event) => {
        seen.push(event.index);
        if (event.index === 0) {
          // Let the worker finish (it has `total - 1` more events to emit, then
          // it returns) and raise the barrier before the queue is drained.
          blockHost(Number(process.env.WASM_ASYNC_BLOCK_MS || "50"));
          instance.prepare();
          barrierPending = instance.pending();
        }
        if (event.index === 1) {
          throw boom;
        }
        return 0;
      })
      .then(
        () => {
          reason = "resolved";
        },
        (error) => {
          reason = error;
        },
      );
    const drained = await drain(instance);
    return {
      barrierPending,
      drained,
      identity: reason === boom,
      primed,
      reasonType: typeof reason,
      seen,
      total,
    };
  },

  /// Plain concurrent threaded tasks (no progress events): the worker pool
  /// itself under load.
  concurrent_tasks: async (instance) => {
    const taskCount = Number(process.env.WASM_ASYNC_TASKS || "8");
    const values = await Promise.all(
      Array.from({ length: taskCount }, (_unused, index) => instance.api.asyncThreadValue(index)),
    );
    const expected = Array.from({ length: taskCount }, (_unused, index) => index + 1);
    return {
      matches: values.length === expected.length && values.every((value, index) => value === expected[index]),
      values,
    };
  },

  /// Barrier exports, idempotency, and the drained count.
  barrier: async (instance) => {
    const before = instance.pending();
    instance.prepare();
    instance.prepare();
    return { before, exports: typeof instance.prepare, pending: instance.pending() };
  },

  /// An in-flight task is rejected by the barrier itself, without any turn of
  /// the event loop, and nothing stays queued behind it.
  cancellation: async (instance) => {
    const long = outcome(instance.api.asyncLongThreadValue(1));
    instance.prepare();
    const pendingRightAfter = instance.pending();
    const settled = await long;
    const drained = await drain(instance);
    return { drained, pendingRightAfter, settled };
  },

  /// Work submitted after the barrier is refused without starting anything.
  refusal: async (instance) => {
    instance.prepare();
    let delivered = 0;
    const refused = await outcome(
      instance.api.asyncSliceEvents(4, () => {
        delivered += 1;
      }),
    );
    return { delivered, pending: instance.pending(), refused };
  },

  /// A finished task whose completion the host has not published yet must still
  /// settle - with the result it produced - when the barrier runs first.
  ///
  /// Deterministic on the worker flavor: the last progress event reaches the
  /// listener *before* the completion callback can (that one travels back from
  /// the worker as its own task), the listener holds this JavaScript turn long
  /// enough for the worker to return, and the barrier then runs from the
  /// microtask continuation of that same turn - still ahead of the completion.
  /// The environment is destroyed right afterwards, exactly like a loader that
  /// saw an empty queue, so a settlement that only the queue could have carried
  /// is lost: without the barrier settling it here the promise strands.
  finished_unpublished: async (instance) => {
    if (!threaded) {
      // Only a worker can get ahead of the host this way: the threadless host
      // runs the task body itself, so a barrier raised from inside a listener
      // always sees a task that is still running (rejected as an abort), and
      // one raised after the task returned always sees a published completion.
      return { skipped: "threadless" };
    }
    // Prime the pool so the task below starts on a live worker immediately.
    const primed = await instance.api.asyncThreadValue(1);
    const total = 3;
    let lastEvent = () => {};
    const lastEventSeen = new Promise((resolve) => {
      lastEvent = resolve;
    });
    const promise = outcome(
      instance.api.asyncSliceEvents(total, (event) => {
        if (event.index === total - 1) {
          // The worker has produced everything it will produce; give it the
          // time to return and mark itself finished, then hand control back.
          blockHost(Number(process.env.WASM_ASYNC_BLOCK_MS || "50"));
          lastEvent();
        }
        return 0;
      }),
    );
    // Runs as a microtask of the turn that dispatched the last event, so it is
    // still ahead of the host's completion callback.
    await lastEventSeen;
    instance.prepare();
    const pendingAtBarrier = instance.pending();
    instance.destroy();
    const settled = await promise;
    const drained = await drain(instance);
    return { drained, pendingAtBarrier, primed, settled };
  },

  /// Progress events past the queue limit: ordered, lossless, and the producer
  /// must never park the event loop (threadless) or lose the wake-up (threaded).
  burst: async (instance) => {
    const limit = instance.api.eventQueueLimit();
    const total = limit * 4;
    const seen = [];
    const value = await instance.api.asyncSliceEvents(total, (event) => {
      seen.push(event.index);
    });
    let firstOutOfOrder = -1;
    for (let index = 0; index < seen.length; index += 1) {
      if (seen[index] !== index) {
        firstOutOfOrder = index;
        break;
      }
    }
    return {
      delivered: seen.length,
      firstOutOfOrder,
      highWater: instance.api.eventQueueHighWater(),
      inline: instance.api.inlineEventDelivery(),
      limit,
      pending: instance.pending(),
      total,
      value,
    };
  },

  /// Concurrent tasks with progress, while the host is briefly blocked: on the
  /// worker flavor the producers fill the bounded queue and have to be woken by
  /// the drain (the atomic wait/notify path), and every event still arrives in
  /// order.
  concurrent_progress: async (instance) => {
    const taskCount = Number(process.env.WASM_ASYNC_TASKS || "4");
    const perTask = Number(
      process.env.WASM_ASYNC_PER_TASK || String(instance.api.eventQueueLimit() * 2),
    );
    const blockMs = Number(process.env.WASM_ASYNC_BLOCK_MS ?? "50");
    const tasks = Array.from({ length: taskCount }, (_unused, index) => index + 1).map((id) => {
      const seen = [];
      return instance.api
        .asyncSliceEvents(perTask, (event) => {
          seen.push(event.index);
        })
        .then((value) => ({ id, seen, value }));
    });
    // Keep the drain from running while the producers fill the queue.
    blockHost(blockMs);
    const results = await Promise.all(tasks);
    const ordered = results.every(
      (result) =>
        result.value === perTask &&
        result.seen.length === perTask &&
        result.seen.every((value, index) => value === index),
    );
    return {
      ordered,
      pending: instance.pending(),
      perTask,
      tasks: results.length,
    };
  },

  /// A throwing listener rejects with its own value, on both flavors.
  listener_throw: async (instance) => {
    const boom = { marker: "wasm-listener" };
    let reason;
    await instance.api
      .asyncThrowingEvents(2, () => {
        throw boom;
      })
      .then(
        () => {
          reason = "resolved";
        },
        (error) => {
          reason = error;
        },
      );
    return { identity: reason === boom, reasonType: typeof reason };
  },
};

const run = scenarios[scenario];
if (!run) {
  console.error(`unknown scenario ${scenario}`);
  process.exit(2);
}

run(instantiate(), { threaded })
  .then((result) => {
    console.log(`RESULT ${JSON.stringify(result)}`);
    // Natural exit: a worker or thread-safe function that is still finalizing is
    // a liveness bug the parent's timeout must catch, not something to mask.
  })
  .catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
