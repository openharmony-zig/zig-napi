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
        {
          cwd: nodeTestDir,
          encoding: "utf8",
          timeout: DEFAULT_TIMEOUT_MS,
          env: { ...process.env },
        },
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
  const { createContext, instantiateNapiModuleSync, emnapiAsyncWorkPlugin, emnapiTSFNPlugin } =
    requireFromPackage("@napi-rs/wasm-runtime");
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
  const { instance, napiModule } = instantiateNapiModuleSync(fs.readFileSync(artifact), options);
  const addon = napiModule.exports;
  const produce = flavor.sharedMemory
    ? (count, listener) => addon.asyncSliceEvents(count, listener)
    : (count, listener) => addon.asyncSliceEventsSingle(count, listener);
  const throwing = flavor.sharedMemory
    ? (count, listener) => addon.asyncThrowingEvents(count, listener)
    : (count, listener) => addon.asyncThrowingEventsSingle(count, listener);

  /// Raw allocator edge cases, straight against the exported C entry points.
  /// Every one of these must report failure through its return value instead of
  /// trapping, in Debug/ReleaseSafe (checked arithmetic, header asserts) and in
  /// ReleaseFast (no checks at all) alike.
  function assertAllocatorEdges(scope) {
    const { malloc, free, calloc, realloc, aligned_alloc, posix_memalign, valloc, memalign } =
      instance.exports;
    const U32_MAX = 0xffffffff;

    // Overflowing size requests: null, not a trap, and errno stays NOMEM.
    assert.strictEqual(malloc(U32_MAX), 0, `${scope}: malloc(UINT32_MAX) must return null`);
    assert.strictEqual(
      calloc(U32_MAX, U32_MAX),
      0,
      `${scope}: calloc multiplication overflow must return null`,
    );
    assert.strictEqual(
      calloc(U32_MAX, 2),
      0,
      `${scope}: calloc with an overflowing product must return null`,
    );

    // Requests near the allocator's big-class limit. `BrkAllocator` indexes a
    // 15 entry table with `log2(pow2_pages)`, so anything that needs more than
    // 2^14 pages (1 GiB) reads past it; the facade has to reject those before
    // the allocator sees them. These return null immediately — the block they
    // ask for is never attempted — so they are safe to run against a normal
    // artifact.
    const GIB = 1 << 30;
    for (const size of [GIB, GIB - 4, GIB - 8, GIB - 4096, GIB + 1, 2 * GIB, U32_MAX - 16]) {
      assert.strictEqual(
        malloc(size),
        0,
        `${scope}: malloc(${size}) near the class limit must return null, not trap`,
      );
    }
    assert.strictEqual(
      realloc(malloc(64), GIB),
      0,
      `${scope}: realloc to the class limit must return null, not trap`,
    );
    assert.strictEqual(
      calloc(1, GIB),
      0,
      `${scope}: calloc at the class limit must return null, not trap`,
    );
    // The alignment is part of the same rounding, so an alignment past the class
    // limit is rejected for any size, including zero.
    for (const alignment of [GIB + 1, 2 * GIB]) {
      assert.strictEqual(
        aligned_alloc(alignment, 0),
        0,
        `${scope}: aligned_alloc(${alignment}, 0) must return null, not trap`,
      );
      assert.strictEqual(
        memalign(alignment, 0),
        0,
        `${scope}: memalign(${alignment}, 0) must return null, not trap`,
      );
    }
    assert.strictEqual(
      aligned_alloc(GIB, 16),
      0,
      `${scope}: aligned_alloc(1 GiB, 16) must return null instead of growing a GiB`,
    );

    // A live block whose payload must survive a failed realloc.
    const payload = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const block = malloc(payload.length);
    assert.notStrictEqual(block, 0, `${scope}: a small malloc must succeed`);
    new Uint8Array(memory.buffer, block >>> 0, payload.length).set(payload);
    assert.strictEqual(
      realloc(block, U32_MAX),
      0,
      `${scope}: realloc to UINT32_MAX must return null`,
    );
    assert.strictEqual(
      realloc(block, U32_MAX - 8),
      0,
      `${scope}: realloc just below the limit must return null, not wrap`,
    );
    assert.deepStrictEqual(
      Array.from(new Uint8Array(memory.buffer, block >>> 0, payload.length)),
      Array.from(payload),
      `${scope}: the original block keeps its payload after a failed realloc`,
    );
    // The block is still live and usable, so it can be grown normally.
    const grown = realloc(block, 4096);
    assert.notStrictEqual(grown, 0, `${scope}: the block is still valid`);
    assert.deepStrictEqual(
      Array.from(new Uint8Array(memory.buffer, grown >>> 0, payload.length)),
      Array.from(payload),
      `${scope}: realloc preserved the payload`,
    );
    free(grown);

    // Alignments `Alignment` cannot represent must be rejected, not asserted.
    for (const alignment of [0, 3, 6, 1000]) {
      assert.strictEqual(
        aligned_alloc(alignment, 16),
        0,
        `${scope}: aligned_alloc(${alignment}) must return null`,
      );
      assert.strictEqual(
        memalign(alignment, 16),
        0,
        `${scope}: memalign(${alignment}) must return null`,
      );
    }
    // A representable but absurd alignment is out of memory, not a trap.
    assert.strictEqual(
      aligned_alloc(1 << 30, 16),
      0,
      `${scope}: aligned_alloc(1<<30) must return null instead of trapping`,
    );

    // posix_memalign: EINVAL (22) for a non power of two or a too small
    // alignment, and the caller's pointer must not be touched on failure.
    const outPointer = malloc(8);
    assert.notStrictEqual(outPointer, 0, `${scope}: scratch block for the out parameter`);
    // A fresh view per access: the views detach when the heap grows, which the
    // workloads above are allowed to do.
    const readOut = () => new DataView(memory.buffer, outPointer >>> 0, 8).getUint32(0, true);
    const writeOut = (value) =>
      new DataView(memory.buffer, outPointer >>> 0, 8).setUint32(0, value, true);
    // wasi-libc numbers errno in the WASI space: EINVAL is 28 there, not the 22
    // Linux/musl use, and the C contract is about the symbol, not the number.
    const WASI_EINVAL = 28;
    // Invalid: not a power of two, or below `sizeof(void*)` (4 on wasm32).
    for (const alignment of [1, 2, 3, 6, 24, 1000]) {
      writeOut(0xdeadbeef);
      const status = posix_memalign(outPointer >>> 0, alignment, 16);
      assert.strictEqual(
        status,
        WASI_EINVAL,
        `${scope}: posix_memalign(${alignment}) must be EINVAL (${WASI_EINVAL})`,
      );
      assert.strictEqual(
        readOut(),
        0xdeadbeef,
        `${scope}: posix_memalign must not write the out parameter on failure`,
      );
    }
    // `sizeof(void*)` is 4 on wasm32, so alignment 4 *is* a valid
    // `posix_memalign` request (it is what the ABI's minimum resolves to) and
    // must succeed rather than be rejected with the invalid ones above.
    writeOut(0xdeadbeef);
    assert.strictEqual(
      posix_memalign(outPointer >>> 0, 4, 16),
      0,
      `${scope}: posix_memalign(4, 16) is valid on wasm32 (sizeof(void*) == 4)`,
    );
    const aligned4 = readOut();
    assert.notStrictEqual(aligned4, 0xdeadbeef, `${scope}: the out parameter is written`);
    assert.notStrictEqual(aligned4, 0, `${scope}: posix_memalign(4) returned a block`);
    assert.strictEqual(aligned4 % 4, 0, `${scope}: posix_memalign(4) honours the alignment`);
    free(aligned4);

    const okStatus = posix_memalign(outPointer >>> 0, 32, 16);
    assert.strictEqual(okStatus, 0, `${scope}: a valid posix_memalign succeeds`);
    const allocated = readOut();
    assert.notStrictEqual(allocated, 0xdeadbeef, `${scope}: the out parameter is written`);
    assert.notStrictEqual(allocated, 0, `${scope}: posix_memalign returned a block`);
    assert.strictEqual(allocated % 32, 0, `${scope}: posix_memalign honours the alignment`);
    free(allocated);
    free(outPointer);

    // valloc is page aligned (64 KiB on wasm), not 16 bytes.
    const pageAligned = valloc(64);
    assert.notStrictEqual(pageAligned, 0, `${scope}: valloc must succeed`);
    assert.strictEqual((pageAligned >>> 0) % 65536, 0, `${scope}: valloc must be page aligned`);
    free(pageAligned);
  }

  /// The Zig-side page allocator (`napi.safePageAllocator()`) is a *second*
  /// `BrkAllocator` instance with the same big-class table, so it needs the same
  /// guard. These probes drive it through the fixture's exports.
  function assertZigPageAllocatorEdges(scope) {
    const { zigPageAlloc, zigPagePattern, zigPageResize, zigPageRemap, zigPageFree } =
      addon;
    for (const name of ["zigPageAlloc", "zigPageResize", "zigPageRemap", "zigPageFree"]) {
      assert.strictEqual(
        typeof addon[name],
        "function",
        `${scope}: the fixture must export \`${name}\` to drive the Zig-side allocator`,
      );
    }

    // Small round trip first: the guard must not disturb the working path. Only
    // the first 4 KiB were written, so the payload check stays inside them.
    const written = 4096;
    let block = zigPageAlloc(written);
    assert.notStrictEqual(block, 0, `${scope}: a 4 KiB Zig allocation must succeed`);
    assert.ok(zigPagePattern(block, written), `${scope}: the block carries its pattern`);

    let size = written;
    if (zigPageResize(block, size, 8192)) {
      size = 8192;
      assert.ok(
        zigPagePattern(block, written),
        `${scope}: an in-place resize keeps the payload`,
      );
    }
    // `remap` may legitimately refuse (the bump allocator only extends its last
    // block); either outcome must leave a payload-carrying block behind.
    const remapped = zigPageRemap(block, size, 8192);
    if (remapped === 0) {
      assert.ok(
        zigPagePattern(block, written),
        `${scope}: a refused remap leaves the block untouched`,
      );
    } else {
      block = remapped;
      size = 8192;
      assert.ok(zigPagePattern(block, written), `${scope}: a remap keeps the payload`);
    }

    // Past the class limit: refusal, not a trap, and the live block survives.
    const GIB = 1 << 30;
    const ONE_PAGE = 64 * 1024;
    for (const size of [GIB, GIB - ONE_PAGE + 1, GIB + 1, 2 * GIB, 0xffffffff]) {
      assert.strictEqual(
        zigPageAlloc(size),
        0,
        `${scope}: zigPageAlloc(${size}) past the class limit must return 0, not trap`,
      );
    }
    assert.strictEqual(
      zigPageResize(block, size, GIB),
      false,
      `${scope}: resize past the class limit must report "not resizable"`,
    );
    assert.ok(
      zigPagePattern(block, written),
      `${scope}: a refused resize leaves the block untouched`,
    );
    assert.strictEqual(
      zigPageRemap(block, size, GIB),
      0,
      `${scope}: remap past the class limit must return 0, not trap`,
    );
    assert.ok(
      zigPagePattern(block, written),
      `${scope}: a refused remap leaves the block untouched`,
    );

    zigPageFree(block, size);
    console.log(`# ${scope}: Zig-side page allocator guard and payload checks passed`);
  }

  assertAllocatorEdges(flavorName);
  assertZigPageAllocatorEdges(flavorName);

  // Warm up the pool so the first measured round is not paying for start-up.
  await produce(8, () => {});
  await gcAndSettle();
  const baselineBytes = addon.activeBytes();
  const baselineAllocations = addon.allocationCount();
  console.log(`# baseline: activeBytes=${baselineBytes} allocations=${baselineAllocations}`);

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
    const work = Array.from({ length: flavor.producers }, () => produce(32, () => {}));
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
    await Promise.all(Array.from({ length: flavor.producers }, () => produce(64, () => {})));
    for (let round = 0; round < 4; round += 1) {
      await Promise.all(Array.from({ length: flavor.producers }, () => produce(32, () => {})));
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

  // 8. The environment still works after all of that. Both flavors link the
  //    hardened allocator; only the threaded one compiles the lock in, so only
  //    it counts entries.
  assert.strictEqual(await produce(4, () => {}), 4, "events still flow after the stress");
  for (const name of ["__emnapi_alloc_entries", "__emnapi_alloc_spins"]) {
    assert.strictEqual(
      typeof instance.exports[name],
      "function",
      `${name} must be linked in both flavors`,
    );
  }
  if (flavor.sharedMemory) {
    assert.strictEqual(await addon.asyncThreadValue(41), 42, "worker tasks still run");
    assert.ok(
      instance.exports.__emnapi_alloc_entries() > 0,
      "the threaded flavor must count its locked entries",
    );
  } else {
    assert.strictEqual(
      instance.exports.__emnapi_alloc_entries(),
      0,
      "the single-threaded flavor compiles the lock away, so nothing is counted",
    );
  }

  console.log("CONCURRENCY OK");
}

if (process.argv.includes(CHILD_FLAG)) {
  childMain().catch((error) => {
    console.error(error && error.stack ? error.stack : `${describeFallback(error)}`);
    process.exitCode = 1;
  });
} else {
  registerTests();
}

function describeFallback(error) {
  return error === undefined ? "undefined error" : String(error);
}
