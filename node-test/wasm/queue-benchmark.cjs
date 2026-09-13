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
// Each child reports allocations / activeBytes / RSS / cpuUsage / duration
// before and after the burst. Nothing here asserts a wall-clock threshold: the
// checks are the delivered event count and order, a bounded retained-bytes
// high-water mark, and a return to the logical allocation baseline once
// JavaScript has collected the event wrappers. That makes the same script
// usable as a before/after comparison across trees, which is what the recorded
// baseline is for.
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
  const {
    createContext,
    instantiateNapiModuleSync,
    emnapiAsyncWorkPlugin,
    emnapiTSFNPlugin,
  } = requireFromPackage("@napi-rs/wasm-runtime");
  const { WASI } = require("node:wasi");
  const { Worker } = require("node:worker_threads");

  const artifact = path.join(
    root,
    `async_audit.${flavor.platformArchABI}.wasm`,
  );
  const rootDir = path.parse(process.cwd()).root;
  const memory = new WebAssembly.Memory({
    initial: 1024,
    maximum: 65536,
    shared: flavor.sharedMemory,
  });
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
  const addon = instantiateNapiModuleSync(fs.readFileSync(artifact), options)
    .napiModule.exports;
  const produce = flavor.sharedMemory
    ? (count, listener) => addon.asyncSliceEvents(count, listener)
    : (count, listener) => addon.asyncSliceEventsSingle(count, listener);

  // Warm up so the first measured burst is not paying for worker start-up.
  await produce(8, () => {});
  await gcAndSettle();

  const retained = [];
  let peakRetained = addon.activeBytes();
  let peakRss = process.memoryUsage().rss;
  const sampler = setInterval(() => {
    peakRetained = Math.max(peakRetained, addon.activeBytes());
    peakRss = Math.max(peakRss, process.memoryUsage().rss);
  }, 5);

  const before = {
    allocations: addon.allocationCount(),
    frees: addon.freeCount(),
    retainedBytes: addon.activeBytes(),
    rss: process.memoryUsage().rss,
    cpu: process.cpuUsage(),
  };

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
  peakRss = Math.max(peakRss, process.memoryUsage().rss);
  const after = {
    allocations: addon.allocationCount(),
    frees: addon.freeCount(),
    retainedBytes: addon.activeBytes(),
    rss: process.memoryUsage().rss,
  };

  assert.strictEqual(produced, events, "the producer reported every event");
  if (mode !== "no-listener") {
    assert.ok(orderOk, "events arrived in index order");
    assert.strictEqual(delivered, events, "the listener observed every event");
  }

  await gcAndSettle();
  const settled = {
    allocations: addon.allocationCount(),
    retainedBytes: addon.activeBytes(),
    rss: process.memoryUsage().rss,
  };
  peakRetained = Math.max(peakRetained, addon.activeBytes());

  const retainedDelta = peakRetained - before.retainedBytes;
  assert.ok(
    retainedDelta <= MAX_RETAINED_BYTES,
    `retained bytes high-water ${retainedDelta} exceeds ${MAX_RETAINED_BYTES} for ${events} events`,
  );
  // The queue must not retain the burst: after GC the logical allocation
  // baseline is back. A little slack covers the work struct of the operation
  // itself and any event still held by the last `setImmediate` turn.
  assert.ok(
    settled.retainedBytes - before.retainedBytes < 64 * 1024,
    `logical allocations did not return to baseline: ` +
      `${before.retainedBytes} -> ${settled.retainedBytes}`,
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
      retainedBytesBefore: before.retainedBytes,
      retainedBytesHighWater: peakRetained,
      retainedBytesSettled: settled.retainedBytes,
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
    parseArg("artifact-root") ??
      process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT ??
      nodeTestDir,
  );
  const events = Number(parseArg("events") ?? 3000);
  const stallMs = Number(parseArg("stall-ms") ?? 300);
  const jsonOnly = process.argv.includes("--json");
  const results = [];

  for (const flavor of selectFlavors()) {
    for (const mode of ["no-listener", "stalled-listener"]) {
      const artifact = path.join(
        root,
        `async_audit.${FLAVOR_META[flavor].platformArchABI}.wasm`,
      );
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
            `retained=${parsed.retainedBytesBefore}->${parsed.retainedBytesHighWater}->${parsed.retainedBytesSettled}`,
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
