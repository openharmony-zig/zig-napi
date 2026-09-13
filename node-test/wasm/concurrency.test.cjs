"use strict";

// Concurrency acceptance for the WASI addon artifacts.
//
//   node --test --test-timeout=300000 node-test/wasm/concurrency.test.cjs
//
// The threaded flavor runs addon tasks on several JavaScript worker threads, and
// those threads share one linear memory: the emnapi plugins allocate work
// records and event payloads with the module's exported `malloc`/`free` from
// every worker. This suite drives several producers at once and checks that the
// shared heap survives it — results stay correct, nothing traps, and the live
// byte count returns to its baseline after GC.
//
// Artifact root: `--artifact-root=<dir>` / `ZIG_NAPI_WASM_ARTIFACT_ROOT`,
// defaulting to `node-test/`. Same shape as `abi.test.cjs`: each flavor runs in
// its own child with a deadline and must exit on its own.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const assert = require("node:assert");

const CHILD_FLAG = "--zig-napi-concurrency-child";
const nodeTestDir = path.resolve(__dirname, "..");
const DEFAULT_TIMEOUT_MS = 240000;
const FLAVORS = [
  { name: "threads", platformArchABI: "wasm32-wasi", sharedMemory: true, producers: 4 },
  { name: "single", platformArchABI: "wasm32-wasip1", sharedMemory: false, producers: 1 },
];

function parseArg(name) {
  const prefix = `--${name}=`;
  const match = process.argv.find((argument) => argument.startsWith(prefix));
  return match ? match.slice(prefix.length) : undefined;
}

function artifactRoot() {
  return path.resolve(
    parseArg("artifact-root") ?? process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT ?? nodeTestDir,
  );
}

function registerTests() {
  const root = artifactRoot();
  for (const flavor of FLAVORS) {
    test(`WASI ${flavor.name} concurrent producers (${flavor.platformArchABI})`, () => {
      const artifact = path.join(root, `async_audit.${flavor.platformArchABI}.wasm`);
      assert.ok(
        fs.existsSync(artifact),
        `missing artifact ${artifact}; build it with ` +
          (flavor.sharedMemory
            ? "`zig build -Dtarget=wasm32-wasi -Dcpu=baseline+atomics+bulk_memory+mutable_globals`"
            : "`zig build -Dtarget=wasm32-wasi`"),
      );

      const result = spawnSync(
        process.execPath,
        ["--expose-gc", __filename, CHILD_FLAG, flavor.name, root],
        { cwd: nodeTestDir, encoding: "utf8", timeout: DEFAULT_TIMEOUT_MS, env: { ...process.env } },
      );
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      assert.strictEqual(
        result.signal,
        null,
        `child was killed by ${result.signal} (it never exited on its own):\n${output}`,
      );
      assert.strictEqual(result.status, 0, `child failed:\n${output}`);
      assert.match(output, /^CONCURRENCY OK$/m, `child did not finish its checks:\n${output}`);
    });
  }
}

async function gcAndSettle() {
  if (typeof global.gc !== "function") return;
  for (let round = 0; round < 3; round += 1) {
    global.gc();
    await new Promise((resolve) => setImmediate(resolve));
  }
}

async function childMain() {
  const flavorName = process.argv[process.argv.indexOf(CHILD_FLAG) + 1];
  const root = process.argv[process.argv.indexOf(CHILD_FLAG) + 2];
  const flavor = FLAVORS.find((entry) => entry.name === flavorName);
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

  const artifact = path.join(root, `async_audit.${flavor.platformArchABI}.wasm`);
  const memory = new WebAssembly.Memory({
    initial: 1024,
    maximum: 65536,
    shared: flavor.sharedMemory,
  });
  const options = {
    context: createContext(),
    wasi: new WASI({ version: "preview1", env: process.env }),
    plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
    asyncWorkPoolSize: flavor.sharedMemory ? flavor.producers : 0,
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
  const { instance, napiModule } = instantiateNapiModuleSync(
    fs.readFileSync(artifact),
    options,
  );
  const addon = napiModule.exports;
  const produce = flavor.sharedMemory
    ? (count, listener) => addon.asyncSliceEvents(count, listener)
    : (count, listener) => addon.asyncSliceEventsSingle(count, listener);
  const throwing = flavor.sharedMemory
    ? (count, listener) => addon.asyncThrowingEvents(count, listener)
    : (count, listener) => addon.asyncThrowingEventsSingle(count, listener);

  const describe = (error) =>
    error && error.stack ? error.stack.split("\n")[0] : String(error);

  // Warm up the pool so the first measured round is not paying for start-up.
  await produce(8, () => {});
  await gcAndSettle();
  const baselineBytes = addon.activeBytes();
  const baselineAllocations = addon.allocationCount();
  console.log(
    `# baseline: activeBytes=${baselineBytes} allocations=${baselineAllocations}`,
  );

  // 1. Four producers emit events at the same time, repeatedly. Every burst is
  //    deep copied through the shared heap while the other producers are in the
  //    middle of their own allocations.
  for (let round = 0; round < 12; round += 1) {
    const bursts = Array.from({ length: flavor.producers }, (_, index) => {
      const collected = [];
      return produce(64, (event) => collected.push(event.text)).then((count) => {
        assert.strictEqual(count, 64, `producer ${index} reported every event`);
        assert.strictEqual(collected.length, 64, `producer ${index} delivered every event`);
        for (let eventIndex = 0; eventIndex < collected.length; eventIndex += 1) {
          assert.strictEqual(
            collected[eventIndex],
            `event-${eventIndex}`,
            `producer ${index} round ${round} delivered a corrupted event`,
          );
        }
      });
    });
    await Promise.all(bursts);
  }
  console.log(`# ${12 * flavor.producers} concurrent bursts delivered in order`);

  // 2. Concurrent producers whose listeners throw: the records are allocated,
  //    published and released while other producers allocate.
  for (let round = 0; round < 8; round += 1) {
    const outcomes = await Promise.allSettled(
      Array.from({ length: flavor.producers }, (_, index) =>
        throwing(16, (event) => {
          if (event.index >= 0) {
            throw new Error(`listener-${index}`);
          }
        }),
      ),
    );
    for (const outcome of outcomes) {
      assert.strictEqual(
        outcome.status,
        "rejected",
        `a throwing listener must reject (got ${JSON.stringify(outcome)})`,
      );
    }
  }
  console.log(`# ${8 * flavor.producers} concurrent throwing bursts rejected cleanly`);

  // 3. Concurrent bursts racing with cancellation.
  if (flavor.sharedMemory && typeof addon.workerCancelled === "function") {
    const cancellations = await Promise.allSettled(
      Array.from({ length: flavor.producers }, () => addon.workerCancelled()),
    );
    for (const outcome of cancellations) {
      assert.ok(
        outcome.status === "fulfilled" || outcome.status === "rejected",
        `cancellation must settle: ${JSON.stringify(outcome)}`,
      );
    }
    console.log("# concurrent cancellations settled");
  }

  // 4. The main thread allocates and frees through the same exported heap while
  //    the workers do the same, which is the interleaving that corrupts an
  //    unsynchronized allocator.
  if (typeof instance.exports.malloc === "function") {
    const allocations = [];
    for (let index = 0; index < 32; index += 1) {
      allocations.push(instance.exports.malloc(128 + index * 8));
    }
    const work = Array.from({ length: flavor.producers }, () =>
      produce(32, () => {}),
    );
    for (const pointer of allocations) {
      instance.exports.free(pointer);
    }
    await Promise.all(work);
    console.log("# main-thread malloc/free interleaved with worker bursts");
  }

  // 5. A repeated malloc/free stress on the exported heap: 200 rounds of
  //    allocate-and-free from JavaScript, checking that the heap keeps serving
  //    distinct blocks and that the live count returns to its baseline.
  const stressPointers = [];
  for (let index = 0; index < 200; index += 1) {
    const pointer = instance.exports.malloc(64);
    assert.notStrictEqual(pointer, 0, `malloc(${index}) must succeed`);
    stressPointers.push(pointer >>> 0);
  }
  const unique = new Set(stressPointers);
  assert.strictEqual(unique.size, 200, "each malloc must return a distinct block");
  for (const pointer of stressPointers) {
    instance.exports.free(pointer);
  }
  const reallocated = instance.exports.malloc(64);
  assert.notStrictEqual(reallocated, 0, "a block is available after the stress");
  instance.exports.free(reallocated);
  console.log("# 200 malloc/free rounds reused the heap without aliasing");

  // 6. The locked allocator is the one actually linked, and the plugins really
  //    go through it: libc's unsynchronized allocator would leave the counter
  //    frozen while the workers allocate.
  if (flavor.sharedMemory) {
    const entries = instance.exports.__emnapi_alloc_entries();
    const spins = instance.exports.__emnapi_alloc_spins();
    console.log(`# emnapi allocator entry points: ${entries}, contended attempts: ${spins}`);
    assert.ok(entries > 0, "the plugins must allocate through the locked allocator");
    assert.ok(
      entries >= baselineAllocations,
      `locked allocator entries (${entries}) must cover the ${baselineAllocations} plugin allocations`,
    );
  }

  // 7. Nothing leaks: run the same workload repeatedly and require the live byte
  //    count to be flat from the second group on. Comparing identical groups
  //    (instead of the pre-workload baseline) isolates retention caused by
  //    concurrency from one-off allocations a workload legitimately makes — and
  //    a per-group growth slope is exactly what a heap that keeps handing out
  //    corrupted blocks looks like.
  const repeatedWorkload = async () => {
    await Promise.all(
      Array.from({ length: flavor.producers }, () => produce(64, () => {})),
    );
    for (let round = 0; round < 4; round += 1) {
      await Promise.all(
        Array.from({ length: flavor.producers }, () => produce(32, () => {})),
      );
    }
  };

  const curve = [];
  for (let group = 0; group < 3; group += 1) {
    await repeatedWorkload();
    await gcAndSettle();
    curve.push({ liveBytes: addon.activeBytes(), allocations: addon.allocationCount() });
  }
  console.log(
    `# repeated workloads (liveBytes, allocations): ${curve
      .map((entry) => `${entry.liveBytes},${entry.allocations}`)
      .join(" | ")}`,
  );
  assert.strictEqual(
    curve[2].liveBytes,
    curve[1].liveBytes,
    `live bytes kept growing across identical workloads: ` +
      `${curve.map((entry) => entry.liveBytes).join(" -> ")}`,
  );
  assert.ok(
    curve[2].allocations >= curve[1].allocations,
    `allocation count went backwards: ${curve[1].allocations} -> ${curve[2].allocations}`,
  );

  // 8. The environment still works after all of that.
  assert.strictEqual(await produce(4, () => {}), 4, "events still flow after the stress");
  if (flavor.sharedMemory) {
    assert.strictEqual(await addon.asyncThreadValue(41), 42, "worker tasks still run");
    for (const name of ["__emnapi_alloc_entries", "__emnapi_alloc_spins"]) {
      assert.strictEqual(
        typeof instance.exports[name],
        "function",
        `${name} is only linked into the threaded flavor`,
      );
    }
  } else {
    // The single-threaded flavor keeps libc's allocator, so the serialized
    // replacements must not be linked there at all.
    assert.strictEqual(
      typeof instance.exports.__emnapi_alloc_entries,
      "undefined",
      "the single-threaded flavor must not link the locked allocator",
    );
  }

  console.log("CONCURRENCY OK");
}

if (process.argv.includes(CHILD_FLAG)) {
  childMain().catch((error) => {
    console.error(
      error && error.stack ? error.stack : `${describeFallback(error)}`,
    );
    process.exitCode = 1;
  });
} else {
  registerTests();
}

function describeFallback(error) {
  return error === undefined ? "undefined error" : String(error);
}
