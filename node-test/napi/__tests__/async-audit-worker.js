// Worker environment used by async-audit.spec.js. It loads its own copy of the
// audit addon so the spec can close a second environment while the main one
// keeps running.
const path = require("path");
const { parentPort, workerData } = require("node:worker_threads");

const loadAddon = require(path.join(__dirname, "..", "..", "load-addon.js"));
const native = loadAddon("async_audit");

async function main() {
  const mode = workerData && workerData.mode ? workerData.mode : "async";

  if (mode === "tsfn-abandon") {
    // Queue calls and never release: the environment teardown must drain the
    // queue with a null environment instead of leaking or touching JS.
    native.queueThreadSafeFunctionAbandon(
      () => {
        // Never reached: the queue is drained after the environment is gone.
      },
      4,
    );
    parentPort.postMessage({ queued: 4 });
    return;
  }

  const value = await native.asyncThreadValue(7);
  parentPort.postMessage({ value });
}

main().catch((error) => {
  parentPort.postMessage({ error: error && error.message ? error.message : String(error) });
});
