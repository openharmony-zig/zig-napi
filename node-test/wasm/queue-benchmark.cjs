"use strict";

// Async event-queue diagnostics for the built WASI addon artifacts.
//
//   node node-test/wasm/queue-benchmark.cjs [--artifact-root=<dir>]
//        [--flavor=threads|single|both] [--events=3000] [--stall-ms=300] [--json]
//
// Two modes run in isolated child processes so one cannot warm the other:
//
//   no-listener       the producer has nobody to hand events to
//   stalled-listener  the listener blocks the JavaScript thread for `stall-ms`
//                     on the first event, which forces the producer through the
//                     bounded queue and its back-pressure path
//
// Each child reports three separate memory dimensions — logical live bytes from
// the addon's counting allocator, the wasm linear memory capacity, and process
// RSS — plus cpuUsage and duration, before / high-water / settled. Nothing here
// asserts a wall-clock threshold. The checks are: the delivered event count and
// order, the addon's own bounded-queue high-water mark (`eventQueueHighWater`
// never above `eventQueueLimit`, and above zero only when a listener actually
// forced events through the queue), a logical-bytes retention bound, and a
// return to the logical allocation baseline once JavaScript has collected the
// event wrappers. That makes the same script usable as a before/after
// comparison across trees, which is what the recorded baseline is for.
//
// Children never call `process.exit`: they finish their work and let Node exit
// by itself, so a leaked handle or a wedged queue shows up as a deadline kill
// (exit code is then non-zero and the parent reports it) instead of being
// masked.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const assert = require("node:assert");

const CHILD_FLAG = "--zig-napi-queue-child";
const nodeTestDir = path.resolve(__dirname, "..");
const DEADLINE_MS = 180000;
// Generous retention ceiling for 3000 events: this is not a performance
// threshold, it only catches "the queue retains every event payload".
const MAX_RETAINED_BYTES = 4 * 1024 * 1024;

function parseArg(name) {
  const prefix = `--${name}=`;
  const match = process.argv.find((argument) => argument.startsWith(prefix));
  return match ? match.slice(prefix.length) : undefined;
}

const FLAVOR_META = {
  threads: { platformArchABI: "wasm32-wasi", sharedMemory: true },
  single: { platformArchABI: "wasm32-wasip1", sharedMemory: false },
};

function selectFlavors() {
  const requested = parseArg("flavor") ?? "both";
  if (requested === "both") return Object.keys(FLAVOR_META);
  assert.ok(FLAVOR_META[requested], `unknown flavor ${requested}`);
  return [requested];
}

function gcAndSettle() {
  if (typeof global.gc !== "function") return Promise.resolve();
  return (async () => {
    for (let round = 0; round < 3; round += 1) {
      global.gc();
      await new Promise((resolve) => setImmediate(resolve));
    }
  })();
}

async function runChild() {
  const flavorName = process.argv[process.argv.indexOf(CHILD_FLAG) + 1];
  const mode = process.argv[process.argv.indexOf(CHILD_FLAG) + 2];
  const root = process.argv[process.argv.indexOf(CHILD_FLAG) + 3];
  const events = Number(process.argv[process.argv.indexOf(CHILD_FLAG) + 4]);
  const stallMs = Number(process.argv[process.argv.indexOf(CHILD_FLAG) + 5]);
  const flavor = FLAVOR_META[flavorName];
  assert.ok(flavor, `unknown flavor ${flavorName}`);

  const requireFromPackage = require("node:module").createRequire(
    path.join(nodeTestDir, "package.json"),
  );
  const { createContext, instantiateNapiModuleSync, emnapiAsyncWorkPlugin, emnapiTSFNPlugin } =
    requireFromPackage("@napi-rs/wasm-runtime");
  const { WASI } = require("node:wasi");
  const { Worker } = require("node:worker_threads");

  const artifact = path.join(root, `async_audit.${flavor.platformArchABI}.wasm`);
  const rootDir = path.parse(process.cwd()).root;
  const memory = new WebAssembly.Memory({
    initial: 1024,
    maximum: 65536,
    shared: flavor.sharedMemory,
  });
  const linearCapacityBytes = () => memory.buffer.byteLength;
  const options = {
    context: createContext(),
    wasi: new WASI({
      version: "preview1",
      env: process.env,
      preopens: { [rootDir]: rootDir },
    }),
    plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
    asyncWorkPoolSize: flavor.sharedMemory ? 4 : 0,
    reuseWorker: flavor.sharedMemory,
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
  if (flavor.sharedMemory) {
    options.onCreateWorker = () =>
      new Worker(path.join(nodeTestDir, "wasi-worker.mjs"), { env: process.env });
  }
  const addon = instantiateNapiModuleSync(fs.readFileSync(artifact), options).napiModule.exports;
  const produce = flavor.sharedMemory
    ? (count, listener) => addon.asyncSliceEvents(count, listener)
    : (count, listener) => addon.asyncSliceEventsSingle(count, listener);

  // The bounded-queue counters are the point of this benchmark: a retained-byte
  // cap alone cannot distinguish "3000 small events fit" from "the queue is
  // bounded". Fail loudly when the fixture does not expose them.
  for (const name of ["eventQueueLimit", "eventQueueHighWater", "resetEventQueueHighWater"]) {
    assert.strictEqual(
      typeof addon[name],
      "function",
      `the fixture must export \`${name}()\` (node-test/napi/src/async_audit.zig) to prove the event queue is bounded`,
    );
  }
  const eventQueueLimit = addon.eventQueueLimit();
  assert.ok(eventQueueLimit > 0, "the fixture reports a positive in-flight event limit");

  // Warm up so the first measured burst is not paying for worker start-up.
  await produce(8, () => {});
  await gcAndSettle();

  let peakRetained = addon.activeBytes();
  let peakLinear = linearCapacityBytes();
  let peakRss = process.memoryUsage().rss;
  const sampler = setInterval(() => {
    peakRetained = Math.max(peakRetained, addon.activeBytes());
    peakLinear = Math.max(peakLinear, linearCapacityBytes());
    peakRss = Math.max(peakRss, process.memoryUsage().rss);
  }, 5);

  const before = {
    allocations: addon.allocationCount(),
    frees: addon.freeCount(),
    logicalBytes: addon.activeBytes(),
    linearBytes: linearCapacityBytes(),
    rss: process.memoryUsage().rss,
    cpu: process.cpuUsage(),
  };
  addon.resetEventQueueHighWater();

  let delivered = 0;
  let orderOk = true;
  const listener =
    mode === "stalled-listener"
      ? (event) => {
          if (delivered === 0) {
            const until = Date.now() + stallMs;
            while (Date.now() < until) {
              // Block the JavaScript thread: the producer must wait on the
              // queue instead of dropping or buffering without bound.
            }
          }
          if (event.index !== delivered) orderOk = false;
          delivered += 1;
        }
      : (event) => {
          if (event.index !== delivered) orderOk = false;
          delivered += 1;
        };

  const startedAt = process.hrtime.bigint();
  const produced =
    mode === "no-listener"
      ? await addon.asyncSliceEventsNoListener(events)
      : await produce(events, listener);
  const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;

  const cpu = process.cpuUsage(before.cpu);
  clearInterval(sampler);
  peakRetained = Math.max(peakRetained, addon.activeBytes());
  peakLinear = Math.max(peakLinear, linearCapacityBytes());
  peakRss = Math.max(peakRss, process.memoryUsage().rss);
  const after = {
    allocations: addon.allocationCount(),
    frees: addon.freeCount(),
    logicalBytes: addon.activeBytes(),
    linearBytes: linearCapacityBytes(),
    rss: process.memoryUsage().rss,
  };
  const eventQueueHighWater = addon.eventQueueHighWater();

  assert.strictEqual(produced, events, "the producer reported every event");
  if (mode !== "no-listener") {
    assert.ok(orderOk, "events arrived in index order");
    assert.strictEqual(delivered, events, "the listener observed every event");
  }

  // Boundedness: the producer never keeps more events in flight than the
  // fixture's limit. A stalled listener has to push the burst through the
  // bounded queue; without a listener nothing is queued at all.
  //
  // The fixture's counters are instantiated per task kind: `eventQueueLimit` /
  // `eventQueueHighWater` read `AsyncWithEvents(..., .thread)`, which is the
  // task this benchmark drives for the threaded flavor. For the
  // single-threaded flavor the burst goes through `AsyncWithEvents(...,
  // .single)` and its JavaScript-side queue, so the threaded counter must stay
  // at zero — asserting that also guards against the two paths sharing state.
  assert.ok(
    eventQueueHighWater <= eventQueueLimit,
    `event queue high-water ${eventQueueHighWater} exceeded the limit ${eventQueueLimit}`,
  );
  if (!flavor.sharedMemory) {
    assert.strictEqual(
      eventQueueHighWater,
      0,
      "the single-threaded fixture must not touch the threaded task's queue counters",
    );
  } else if (mode === "stalled-listener") {
    assert.ok(
      eventQueueHighWater > 0,
      "a stalled listener must force events through the bounded queue (high-water stayed 0)",
    );
  } else {
    assert.strictEqual(eventQueueHighWater, 0, "without a listener no event may be queued");
  }

  await gcAndSettle();
  const settled = {
    allocations: addon.allocationCount(),
    logicalBytes: addon.activeBytes(),
    linearBytes: linearCapacityBytes(),
    rss: process.memoryUsage().rss,
  };
  peakRetained = Math.max(peakRetained, addon.activeBytes());

  const retainedDelta = peakRetained - before.logicalBytes;
  assert.ok(
    retainedDelta <= MAX_RETAINED_BYTES,
    `logical bytes high-water ${retainedDelta} exceeds ${MAX_RETAINED_BYTES} for ${events} events`,
  );
  // The queue must not retain the burst: after GC the logical allocation
  // baseline is back. A little slack covers the work struct of the operation
  // itself and any event still held by the last `setImmediate` turn.
  assert.ok(
    settled.logicalBytes - before.logicalBytes < 64 * 1024,
    `logical allocations did not return to baseline: ` +
      `${before.logicalBytes} -> ${settled.logicalBytes}`,
  );

  console.log(
    JSON.stringify({
      kind: "queue-benchmark",
      flavor: flavorName,
      platformArchABI: flavor.platformArchABI,
      mode,
      events,
      stallMs: mode === "stalled-listener" ? stallMs : 0,
      durationMs: Number(durationMs.toFixed(2)),
      cpuUserMs: Number((cpu.user / 1000).toFixed(2)),
      cpuSystemMs: Number((cpu.system / 1000).toFixed(2)),
      allocations: after.allocations - before.allocations,
      frees: after.frees - before.frees,
      eventQueueLimit,
      eventQueueHighWater,
      // Three distinct memory dimensions: logical live bytes owned by the
      // addon's allocator, the wasm linear memory capacity (a reservation, the
      // loader's business), and process RSS (which also covers V8 and the
      // worker threads).
      logicalBytesBefore: before.logicalBytes,
      logicalBytesHighWater: peakRetained,
      logicalBytesSettled: settled.logicalBytes,
      linearBytesBefore: before.linearBytes,
      linearBytesHighWater: peakLinear,
      linearBytesSettled: settled.linearBytes,
      rssBefore: before.rss,
      rssHighWater: peakRss,
      rssSettled: settled.rss,
    }),
  );
}

// ---------------------------------------------------------------------------
// Parent driver
// ---------------------------------------------------------------------------

function main() {
  const root = path.resolve(
    parseArg("artifact-root") ?? process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT ?? nodeTestDir,
  );
  const events = Number(parseArg("events") ?? 3000);
  const stallMs = Number(parseArg("stall-ms") ?? 300);
  const jsonOnly = process.argv.includes("--json");
  const results = [];

  for (const flavor of selectFlavors()) {
    for (const mode of ["no-listener", "stalled-listener"]) {
      const artifact = path.join(root, `async_audit.${FLAVOR_META[flavor].platformArchABI}.wasm`);
      assert.ok(fs.existsSync(artifact), `missing artifact ${artifact}`);

      const result = spawnSync(
        process.execPath,
        [
          "--expose-gc",
          __filename,
          CHILD_FLAG,
          flavor,
          mode,
          root,
          String(events),
          String(stallMs),
        ],
        { cwd: nodeTestDir, encoding: "utf8", timeout: DEADLINE_MS, env: { ...process.env } },
      );
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      if (result.signal !== null || result.status !== 0) {
        throw new Error(
          `queue-benchmark child (${flavor}, ${mode}) failed ` +
            `(signal=${result.signal}, status=${result.status}):\n${output}`,
        );
      }
      const line = output
        .split("\n")
        .find((candidate) => candidate.startsWith('{"kind":"queue-benchmark"'));
      assert.ok(line, `child (${flavor}, ${mode}) printed no result:\n${output}`);
      const parsed = JSON.parse(line);
      results.push(parsed);
      if (!jsonOnly) {
        console.log(
          [
            `${parsed.flavor.padEnd(8)} ${parsed.mode.padEnd(17)}`,
            `events=${parsed.events}`,
            `duration=${parsed.durationMs}ms`,
            `cpu=${(parsed.cpuUserMs + parsed.cpuSystemMs).toFixed(2)}ms`,
            `alloc=+${parsed.allocations}`,
            `queue=${parsed.eventQueueHighWater}/${parsed.eventQueueLimit}`,
            `logical=${parsed.logicalBytesBefore}->${parsed.logicalBytesHighWater}->${parsed.logicalBytesSettled}`,
            `linear=${(parsed.linearBytesBefore / 1048576).toFixed(1)}->${(parsed.linearBytesHighWater / 1048576).toFixed(1)}->${(parsed.linearBytesSettled / 1048576).toFixed(1)}MiB`,
            `rss=${(parsed.rssBefore / 1048576).toFixed(1)}->${(parsed.rssHighWater / 1048576).toFixed(1)}->${(parsed.rssSettled / 1048576).toFixed(1)}MiB`,
          ].join("  "),
        );
      }
    }
  }

  if (jsonOnly) {
    console.log(JSON.stringify({ kind: "queue-benchmark-summary", results }, null, 2));
  }
}

if (process.argv.includes(CHILD_FLAG)) {
  runChild().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exitCode = 1;
  });
} else {
  main();
}
