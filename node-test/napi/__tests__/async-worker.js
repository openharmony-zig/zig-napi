// Worker environment used by async.spec.js. It loads its own copy of the
// async_tasks addon so the spec can close a second environment while the main
// one keeps running.
const path = require("path");
// No `node:` prefix: this file is loaded on Node versions that do not
// support it.
const { parentPort, workerData } = require("worker_threads");

// `workerData.loader` lets the spec run this file from a child process whose
// working directory is not the repository; the default keeps direct use simple.
const loader =
  (workerData && workerData.loader) || path.join(__dirname, "..", "..", "load-addon.js");
const native = require(loader)("async_tasks");

async function main() {
  const mode = workerData && workerData.mode ? workerData.mode : "async";

  if (mode === "tsfn-abandon") {
    // Queue calls and never release: the environment teardown must drain the
    // queue with a null environment instead of leaking or touching JS.
    native.queueThreadSafeFunctionAbandon(() => {
      // Never reached: the queue is drained after the environment is gone.
    }, 4);
    parentPort.postMessage({ queued: 4 });
    return;
  }

  if (mode === "async-slow") {
    // Start a threaded task and abandon it: the environment is torn down while
    // the task's controller is still running on a runtime pool worker.
    native.asyncLongThreadValue(5).catch(() => {});
    parentPort.postMessage({ started: true });
    return;
  }

  if (mode === "async-counted-slow") {
    // Same, but the runner counts its completion in the addon's process wide
    // state, so the parent can prove the producer ran to the end after its
    // environment was gone.
    native.asyncCountedThreadValue(5).catch(() => {});
    parentPort.postMessage({ started: true });
    return;
  }

  if (mode === "async-abandoned-abortable") {
    // A signal is bound too: tearing the environment down must not free the
    // operation (or its abort registration) while the task is still running.
    native.asyncAbandonedAbortable(200000000, new AbortController().signal).catch(() => {});
    parentPort.postMessage({ started: true });
    return;
  }

  if (mode === "events-abandoned") {
    // Fewer events than the queue limit, so the producer finishes and drops its
    // reference while the records are still queued; the listener blocks this
    // thread so nothing is drained either. Node runs the finalizer before it
    // drains the queue with a null environment, so at that moment the only
    // thing keeping the operation alive is the reference each queued record
    // owns.
    native
      .asyncSliceEvents(64, (event) => {
        if (event.index === 0) {
          const until = Date.now() + 600;
          while (Date.now() < until) {
            // busy wait
          }
        }
      })
      .catch(() => {});
    parentPort.postMessage({ started: true });
    return;
  }

  const value = await native.asyncThreadValue(7);
  parentPort.postMessage({ value });
}

main().catch((error) => {
  parentPort.postMessage({ error: error && error.message ? error.message : String(error) });
});
