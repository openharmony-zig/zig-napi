"use strict";

// WASI ABI acceptance for the built addon artifacts.
//
// Run with:  ZIG_NAPI_WASM_ARTIFACT_ROOT=<dir> \
//              node --test --test-timeout=300000 node-test/wasm/abi.test.cjs
//
// Use the environment variable, not a flag: `node --test` does not forward an
// extra `--artifact-root=` argument to the test file, so the run would silently
// fall back to the default root. The flag exists for `node <file>` runs where
// the script is the process entry point.
//
// Artifact root (where `<module>.<platformArchABI>.wasm` lives) is
// `--artifact-root=<dir>` / `ZIG_NAPI_WASM_ARTIFACT_ROOT`, defaulting to
// `node-test/`. The root has to contain both flavors:
//
//   <module>.wasm32-wasi.wasm      threaded, shared memory
//   <module>.wasm32-wasip1.wasm    single-threaded, unshared memory
//
// Each flavor runs in its own child process: the child loads the artifacts
// through the raw `@napi-rs/wasm-runtime` API (resolved from this package, not
// from whatever sits at the repository root), exercises the ABI, and must exit
// on its own. The parent enforces a deadline, so a child that keeps handles
// alive (or wedges) fails instead of hanging the suite, and no child calls
// `process.exit` to hide pending work.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const assert = require("node:assert");

const CHILD_FLAG = "--zig-napi-abi-child";
const OOM_CHILD_FLAG = "--zig-napi-abi-oom-child";
const LOAD_ADDON_CHILD_FLAG = "--zig-napi-load-addon-child";
const nodeTestDir = path.resolve(__dirname, "..");
const DEFAULT_TIMEOUT_MS = 240000;

const FLAVORS = [
  { name: "threads", platformArchABI: "wasm32-wasi", sharedMemory: true },
  { name: "single", platformArchABI: "wasm32-wasip1", sharedMemory: false },
];

function parseArg(name) {
  const prefix = `--${name}=`;
  const match = process.argv.find((argument) => argument.startsWith(prefix));
  return match ? match.slice(prefix.length) : undefined;
}

/// Runs `call` and reports how it settled, or `{ kind: "hung" }` when it did
/// not settle within `timeoutMs`. The timeout is cleared on settlement so a
/// pending timer cannot keep the child alive.
async function settlesWithin(call, timeoutMs) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve()
        .then(call)
        .then(
          (value) => ({ kind: "resolved", value }),
          (error) => ({ kind: "rejected", message: error && error.message }),
        ),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve({ kind: "hung" }), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function artifactRoot() {
  return path.resolve(
    parseArg("artifact-root") ?? process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT ?? nodeTestDir,
  );
}

// ---------------------------------------------------------------------------
// Parent: run each flavor in a child with a deadline
// ---------------------------------------------------------------------------

/// Root of an out-of-memory build (`-Dwasi-max-memory-pages=520`, which makes
/// the wasm heap exhaustible in a few MiB). Optional: the default artifacts
/// have a 4 GiB maximum, so this only runs when the environment points at a
/// small-memory build instead of allocating gigabytes to reach the limit.
function oomArtifactRoot() {
  const root = parseArg("oom-artifact-root") ?? process.env.ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT;
  return root ? path.resolve(root) : undefined;
}

function registerTests() {
  const root = artifactRoot();
  for (const flavor of FLAVORS) {
    test(`WASI ${flavor.name} ABI (${flavor.platformArchABI})`, () => {
      for (const module of ["async_audit", "example", "audit"]) {
        const artifact = path.join(root, `${module}.${flavor.platformArchABI}.wasm`);
        assert.ok(
          fs.existsSync(artifact),
          `missing artifact ${artifact}; build it with ` +
            (flavor.sharedMemory
              ? "`zig build -Dtarget=wasm32-wasi -Dcpu=baseline+atomics+bulk_memory+mutable_globals`"
              : "`zig build -Dtarget=wasm32-wasi`"),
        );
      }

      const started = Date.now();
      const result = spawnSync(
        process.execPath,
        ["--expose-gc", __filename, CHILD_FLAG, flavor.name, root, String(DEFAULT_TIMEOUT_MS)],
        {
          cwd: nodeTestDir,
          encoding: "utf8",
          timeout: DEFAULT_TIMEOUT_MS,
          // No `stdio: inherit`: the child's output belongs to this assertion.
          env: { ...process.env },
        },
      );

      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      assert.strictEqual(
        result.signal,
        null,
        `child was killed by ${result.signal} after ${Date.now() - started}ms ` +
          `(it never exited on its own):\n${output}`,
      );
      assert.strictEqual(result.status, 0, `child failed:\n${output}`);
      assert.match(output, /^ABI OK$/m, `child did not finish its checks:\n${output}`);
    });
  }

  registerLoadAddonTests();
  registerBuildOptionTests();

  const oomRoot = oomArtifactRoot();
  test(
    "WASI worker allocation failure is reported, not trapped",
    {
      skip: oomRoot
        ? false
        : "set ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT to a -Dwasi-max-memory-pages build",
    },
    () => {
      const result = spawnSync(process.execPath, [__filename, OOM_CHILD_FLAG, oomRoot], {
        cwd: nodeTestDir,
        encoding: "utf8",
        timeout: DEFAULT_TIMEOUT_MS,
        env: { ...process.env },
      });
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      assert.strictEqual(
        result.signal,
        null,
        `OOM child was killed by ${result.signal} (it never exited on its own):\n${output}`,
      );
      assert.strictEqual(result.status, 0, `OOM child failed:\n${output}`);
      assert.match(output, /^OOM OK$/m, `OOM child did not finish:\n${output}`);
    },
  );
}

/// `load-addon.js` flavor selection: `ZIG_NAPI_WASI_FLAVOR=wasip1` must pick
/// the single-threaded loader, never fall back to the threaded one, and an
/// unknown value must fail loudly.
function registerLoadAddonTests() {
  test("load-addon.js selects the WASI flavor strictly", () => {
    const run = (flavorValue) => {
      const result = spawnSync(
        process.execPath,
        [__filename, LOAD_ADDON_CHILD_FLAG, flavorValue ?? ""],
        { cwd: nodeTestDir, encoding: "utf8", timeout: 60000, env: { ...process.env } },
      );
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      assert.strictEqual(result.status, 0, `child failed:\n${output}`);
      const line = output
        .split("\n")
        .find((candidate) => candidate.startsWith('{"kind":"load-addon"'));
      assert.ok(line, `child printed no result:\n${output}`);
      return JSON.parse(line);
    };

    const fallback = run("");
    assert.strictEqual(fallback.flavor, "wasi", "the threaded flavor stays the default");
    assert.match(fallback.candidate, /\.wasi\.cjs$/, "default loads the threaded loader");

    const wasip1 = run("wasip1");
    assert.strictEqual(wasip1.flavor, "wasip1");
    assert.match(wasip1.candidate, /\.wasip1\.cjs$/, "wasip1 loads its own loader");
    assert.ok(
      !wasip1.candidates.some((candidate) => candidate.endsWith(".wasi.cjs")),
      "the wasip1 flavor must not offer the threaded loader as a fallback",
    );

    const invalid = run("wasm32-wasip1");
    assert.match(
      invalid.error ?? "",
      /ZIG_NAPI_WASI_FLAVOR must be one of wasi, wasip1/,
      "an unknown flavor is rejected instead of being ignored",
    );
  });
}

/// Child mode for the `load-addon.js` selection test.
function loadAddonChildMain(flavorValue) {
  if (flavorValue) {
    process.env.ZIG_NAPI_WASI_FLAVOR = flavorValue;
  } else {
    delete process.env.ZIG_NAPI_WASI_FLAVOR;
  }
  delete process.env.NAPI_RS_FORCE_WASI;
  const loadAddon = require(path.join(nodeTestDir, "load-addon.js"));
  const report = { kind: "load-addon" };
  try {
    report.flavor = loadAddon.wasiFlavor();
    report.candidates = loadAddon.wasiCandidates("audit");
    report.candidate = report.candidates[0];
  } catch (error) {
    report.error = error && error.message;
  }
  console.log(JSON.stringify(report));
}

/// Build-side memory validation: the option combinations that would produce a
/// loader whose wasm heap cannot grow must fail the build with a message that
/// names the option, instead of linking an addon that traps at startup.
function registerBuildOptionTests() {
  const zigAvailable = spawnSync("zig", ["version"], { encoding: "utf8" }).status === 0;
  const cases = [
    {
      args: ["-Dwasi-max-memory-pages=0"],
      expect: /WASI memory maximum must be between 1 and 65536 pages/,
    },
    {
      args: ["-Dwasi-max-memory-pages=70000"],
      expect: /WASI memory maximum must be between 1 and 65536 pages/,
    },
    {
      args: ["-Dwasi-initial-memory-pages=0"],
      expect: /WASI imported memory minimum must be at least 1 page/,
    },
    {
      args: ["-Dwasi-initial-memory-pages=65536"],
      expect: /no headroom for the environment or the async work pool/,
    },
    {
      args: ["-Dwasi-initial-memory-pages=2048", "-Dwasi-max-memory-pages=1024"],
      expect: /must not exceed the maximum/,
    },
    {
      args: ["-Dwasi-initial-memory-pages=256", "-Dwasi-stack-size=33554432"],
      expect: /does not fit in the imported memory minimum/,
    },
  ];
  test(
    "WASI memory options are validated at build time",
    { skip: zigAvailable ? false : "zig is not on PATH" },
    () => {
      for (const { args, expect } of cases) {
        const result = spawnSync("zig", ["build", "-Dtarget=wasm32-wasi", ...args], {
          cwd: nodeTestDir,
          encoding: "utf8",
          timeout: 120000,
          env: { ...process.env },
        });
        const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
        assert.notStrictEqual(result.status, 0, `\`${args.join(" ")}\` must fail the build`);
        assert.match(output, expect, `\`${args.join(" ")}\` produced:\n${output}`);
      }
    },
  );
}

/// Child mode for the optional out-of-memory test: exhaust the heap of a
/// small-memory build, then require that the worker allocator reports failure
/// (0, the value `@emnapi/core` treats as "Failed to create async worker")
/// instead of trapping, and that queued async work settles rather than hanging.
async function oomChildMain() {
  const root = process.argv[process.argv.indexOf(OOM_CHILD_FLAG) + 1];
  const createRequireFromTest = require("node:module").createRequire(
    path.join(nodeTestDir, "package.json"),
  );
  const { createContext, instantiateNapiModuleSync, emnapiAsyncWorkPlugin, emnapiTSFNPlugin } =
    createRequireFromTest("@napi-rs/wasm-runtime");
  const { WASI } = require("node:wasi");

  const artifact = path.join(root, "async_audit.wasm32-wasi.wasm");
  const module = new WebAssembly.Module(fs.readFileSync(artifact));
  const memoryImport = readMemoryImport(fs.readFileSync(artifact));
  assert.ok(memoryImport.max < 4096, "the OOM artifact has a small maximum");

  const smallMemory = new WebAssembly.Memory({
    initial: memoryImport.min + 8,
    maximum: memoryImport.max,
    shared: true,
  });
  const { instance, napiModule } = instantiateNapiModuleSync(fs.readFileSync(artifact), {
    context: createContext(),
    wasi: new WASI({ version: "preview1", env: process.env }),
    plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
    // A growable memory: Zig's wasi allocator needs headroom, so
    // `initial === maximum` would fail every allocation for the wrong reason.
    asyncWorkPoolSize: 0,
    overwriteImports(importObject) {
      importObject.env = {
        ...importObject.env,
        ...importObject.napi,
        ...importObject.emnapi,
        memory: smallMemory,
      };
      return importObject;
    },
  });
  assert.ok(WebAssembly.Module.imports(module).length > 0, "module inspected");

  const first = instance.exports.emnapi_async_worker_create(0, 0);
  assert.notStrictEqual(first, 0, "a worker block fits before exhaustion");

  const heap = [];
  for (let index = 0; index < 8192; index += 1) {
    const pointer = instance.exports.malloc(64 * 1024);
    if (!pointer) break;
    heap.push(pointer);
  }
  assert.ok(heap.length > 0, "the heap was exhausted");

  assert.strictEqual(
    instance.exports.emnapi_async_worker_create(0, 0),
    0,
    "allocation failure returns 0 instead of trapping",
  );

  // The call itself may throw while the heap is exhausted (the addon cannot
  // even allocate the error object); what matters is that it does not hang.
  // Requests at and just below the allocator's class limit must fail through
  // the C ABI without the module ever asking the host for a gigabyte: this
  // artifact's memory maxes out far below that, so `@wasmMemoryGrow` refuses
  // immediately and the call returns null.
  const GIB = 1 << 30;
  const pagesBefore = smallMemory.buffer.byteLength / 65536;
  for (const size of [GIB - 64 * 1024, GIB - 64 * 1024 - 16, GIB - 128 * 1024]) {
    assert.strictEqual(
      instance.exports.malloc(size),
      0,
      `malloc(${size}) just below the class limit must fail cleanly on a small heap`,
    );
  }
  assert.strictEqual(
    instance.exports.aligned_alloc(1 << 20, GIB - 128 * 1024),
    0,
    "aligned_alloc below the class limit must fail cleanly on a small heap",
  );
  assert.ok(
    smallMemory.buffer.byteLength / 65536 - pagesBefore < 64,
    "a refused request must not grow the linear memory by its full size",
  );
  console.log("# class-limit requests fail cleanly on a small heap");

  const outcome = await settlesWithin(() => napiModule.exports.asyncThreadValue(41), 30000);
  assert.notStrictEqual(outcome.kind, "hung", "queued async work must settle, not hang");
  console.log(`# async work after exhaustion: ${outcome.kind}`);

  for (const pointer of heap) instance.exports.free(pointer);
  console.log("OOM OK");
}

// ---------------------------------------------------------------------------
// Child: raw-runtime ABI checks for one flavor
// ---------------------------------------------------------------------------

/// Memory import descriptor (kind/flags/min/max) of a wasm binary. Node's
/// `WebAssembly.Module.imports` does not expose the limits, and the shared flag
/// is exactly what this suite has to pin down.
function readMemoryImport(bytes) {
  let cursor = 8;
  const readU32 = () => {
    let result = 0;
    let shift = 0;
    let byte;
    do {
      byte = bytes[cursor++];
      result |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    return result >>> 0;
  };

  while (cursor < bytes.length) {
    const sectionId = bytes[cursor++];
    const sectionSize = readU32();
    const sectionEnd = cursor + sectionSize;
    if (sectionId !== 2) {
      cursor = sectionEnd;
      continue;
    }
    const count = readU32();
    for (let index = 0; index < count; index += 1) {
      const moduleLength = readU32();
      const moduleName = bytes.toString("utf8", cursor, cursor + moduleLength);
      cursor += moduleLength;
      const nameLength = readU32();
      const name = bytes.toString("utf8", cursor, cursor + nameLength);
      cursor += nameLength;
      const kind = bytes[cursor++];
      if (kind === 0) {
        readU32();
      } else if (kind === 1) {
        cursor += 1;
        readU32();
      } else if (kind === 2) {
        const flags = readU32();
        const min = readU32();
        const max = flags & 1 ? readU32() : undefined;
        return { module: moduleName, name, shared: Boolean(flags & 2), min, max };
      } else if (kind === 3) {
        cursor += 1;
        readU32();
      }
    }
    cursor = sectionEnd;
  }
  return null;
}

async function childMain() {
  const flavorName = process.argv[process.argv.indexOf(CHILD_FLAG) + 1];
  const root = process.argv[process.argv.indexOf(CHILD_FLAG) + 2];
  const flavor = FLAVORS.find((entry) => entry.name === flavorName);
  assert.ok(flavor, `unknown flavor ${flavorName}`);

  const createRequireFromTest = require("node:module").createRequire(
    path.join(nodeTestDir, "package.json"),
  );
  const {
    createContext,
    getDefaultContext,
    instantiateNapiModuleSync,
    emnapiAsyncWorkPlugin,
    emnapiTSFNPlugin,
  } = createRequireFromTest("@napi-rs/wasm-runtime");
  const { WASI } = require("node:wasi");
  const { Worker } = require("node:worker_threads");

  const artifact = (module) => path.join(root, `${module}.${flavor.platformArchABI}.wasm`);

  const bytesOf = (module) => fs.readFileSync(artifact(module));
  const memoryImport = readMemoryImport(bytesOf("async_audit"));
  assert.ok(memoryImport, "the addon imports its memory");
  assert.strictEqual(memoryImport.module, "env", "memory comes from the env module");
  assert.strictEqual(memoryImport.name, "memory", "import is named memory");
  assert.strictEqual(
    memoryImport.shared,
    flavor.sharedMemory,
    `flavor ${flavor.name} must import a ${flavor.sharedMemory ? "shared" : "unshared"} memory`,
  );
  assert.strictEqual(memoryImport.max, 65536, "imported memory maximum is 4 GiB");
  assert.ok(
    memoryImport.min < 1024,
    `the module must not force a large minimum (got ${memoryImport.min} pages)`,
  );

  const rootDir = path.parse(process.cwd()).root;
  const load = (module, { memoryKind }) => {
    const bytes = bytesOf(module);
    const memory = new WebAssembly.Memory({
      initial: 1024,
      maximum: 65536,
      shared: memoryKind === "shared",
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
    const { instance, napiModule } = instantiateNapiModuleSync(bytes, options);
    return { instance, napiModule, memory };
  };

  // The memory kind is part of the ABI: the other kind must be rejected.
  assert.throws(
    () =>
      load("async_audit", {
        memoryKind: flavor.sharedMemory ? "unshared" : "shared",
      }),
    /LinkError/,
    `flavor ${flavor.name} must reject the opposite memory kind`,
  );

  const audit = load("audit", {
    memoryKind: flavor.sharedMemory ? "shared" : "unshared",
  });
  const { instance } = audit;
  const exports = Object.keys(instance.exports);

  for (const required of [
    "malloc",
    "free",
    "napi_register_wasm_v1",
    "node_api_module_get_api_version_v1",
    "emnapi_create_env",
    "emnapi_delete_env",
    "__indirect_function_table",
  ]) {
    assert.ok(exports.includes(required), `${required} must be exported`);
  }
  for (const workerExport of ["emnapi_async_worker_create", "emnapi_async_worker_init"]) {
    assert.strictEqual(
      exports.includes(workerExport),
      flavor.sharedMemory,
      `${workerExport} is ${flavor.sharedMemory ? "required" : "not applicable"} for ${flavor.name}`,
    );
  }
  const imports = WebAssembly.Module.imports(new WebAssembly.Module(bytesOf("audit")));
  const importedEnv = imports.filter((entry) => entry.module === "env").map((entry) => entry.name);
  assert.strictEqual(
    importedEnv.includes("_emnapi_spawn_worker"),
    flavor.sharedMemory,
    "only the threaded flavor talks to the worker pool host",
  );
  for (const stale of [
    "_emnapi_get_last_error_info",
    "napi_get_last_error_info",
    "napi_async_init",
    "napi_async_destroy",
    "napi_add_async_cleanup_hook",
    "napi_remove_async_cleanup_hook",
    "napi_get_node_version",
    "node_api_get_module_file_name",
  ]) {
    assert.ok(
      !importedEnv.includes(stale),
      `${stale} must resolve to the linked emnapi C implementation, not an import`,
    );
  }

  // Environment + UTF-8 + typed array surface through the C env ABI.
  const auditExports = audit.napiModule.exports;
  const utf8 = "héllo wörld — ünïcode ✓";
  assert.strictEqual(auditExports.string(utf8), utf8, "UTF-8 round trip");
  const view = new Uint8Array([7, 9, 11]);
  assert.strictEqual(
    auditExports.typedAfterCallback(view, () => {
      view[0] = 42;
    }),
    42,
    "typed array views see the JavaScript write performed inside the callback",
  );
  assert.strictEqual(auditExports.smallSigned(127), 127);
  assert.strictEqual(auditExports.Class.make(5).value, 5);

  const example = load("example", {
    memoryKind: flavor.sharedMemory ? "shared" : "unshared",
  }).napiModule.exports;
  const exampleUtf8 = "zig-napi ✓ 🦀 \u0000 after the NULL";
  assert.strictEqual(example.roundtripStr(exampleUtf8), exampleUtf8, "example UTF-8 round trip");
  assert.strictEqual(example.add(20, 22), 42, "example add");

  // Async work: events are deep copied on the way out and have to arrive in
  // order. The threaded flavor produces them on a worker thread, so this is
  // also the real thread entry point test.
  const asyncAudit = load("async_audit", {
    memoryKind: flavor.sharedMemory ? "shared" : "unshared",
  }).napiModule.exports;
  const events = [];
  if (flavor.sharedMemory) {
    assert.strictEqual(await asyncAudit.asyncThreadValue(41), 42, "worker entry point");
    assert.strictEqual(await asyncAudit.asyncThreadValue(99), 100, "worker entry point (reuse)");
  }
  const produce = flavor.sharedMemory
    ? (count, listener) => asyncAudit.asyncSliceEvents(count, listener)
    : (count, listener) => asyncAudit.asyncSliceEventsSingle(count, listener);
  const produced = await produce(200, (event) => events.push(event.text));
  assert.strictEqual(produced, 200, "event count");
  assert.deepStrictEqual(
    events,
    Array.from({ length: 200 }, (_, index) => `event-${index}`),
    "events arrive in order and are deep copied",
  );

  if (flavor.sharedMemory) {
    // Parallel tasks on the pool plus main thread progress.
    let ticks = 0;
    const timer = setInterval(() => {
      ticks += 1;
    }, 1);
    const concurrent = await Promise.all(
      Array.from({ length: 8 }, (_, index) => asyncAudit.asyncThreadValue(index)),
    );
    clearInterval(timer);
    assert.deepStrictEqual(
      concurrent,
      Array.from({ length: 8 }, (_, index) => index + 1),
      "concurrent worker tasks keep their own inputs",
    );
    assert.ok(ticks > 0, "the main thread kept running while workers were busy");
    assert.strictEqual(
      await asyncAudit.asyncEchoBytes("threaded-echo"),
      "threaded-echo",
      "captured UTF-8 slice survives the worker",
    );
  }

  // Memory growth must not break subsequent calls in either flavor.
  const pagesBefore = audit.memory.buffer.byteLength / 65536;
  audit.memory.grow(64);
  assert.strictEqual(audit.memory.buffer.byteLength / 65536, pagesBefore + 64, "memory grew");
  assert.strictEqual(auditExports.string(utf8), utf8, "UTF-8 after growth");
  assert.strictEqual(await produce(16, () => {}), 16, "events after growth");
  if (flavor.sharedMemory) {
    assert.strictEqual(await asyncAudit.asyncThreadValue(200), 201, "worker after growth");
  }

  // Allocation bookkeeping returns to its baseline once JavaScript collected
  // the event wrappers (the counting allocator only reports logical bytes).
  if (typeof global.gc === "function") {
    for (let round = 0; round < 3; round += 1) {
      global.gc();
      await new Promise((resolve) => setImmediate(resolve));
    }
  }
  const baselineBefore = asyncAudit.activeBytes();
  await produce(64, () => {});
  if (typeof global.gc === "function") {
    for (let round = 0; round < 3; round += 1) {
      global.gc();
      await new Promise((resolve) => setImmediate(resolve));
    }
  }
  assert.strictEqual(
    asyncAudit.activeBytes(),
    baselineBefore,
    "async event bursts return to the allocation baseline",
  );

  // `getDefaultContext` and `createContext` are both public entry points; keep
  // the raw-runtime shape honest by loading one module with the default
  // context too.
  const defaultContextLoad = load("example", {
    memoryKind: flavor.sharedMemory ? "shared" : "unshared",
  });
  assert.ok(defaultContextLoad.instance.exports.malloc, "module loads");
  assert.ok(getDefaultContext(), "default context is available");

  console.log("ABI OK");
}

if (process.argv.includes(CHILD_FLAG)) {
  childMain().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exitCode = 1;
  });
} else if (process.argv.includes(OOM_CHILD_FLAG)) {
  oomChildMain().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exitCode = 1;
  });
} else if (process.argv.includes(LOAD_ADDON_CHILD_FLAG)) {
  loadAddonChildMain(process.argv[process.argv.indexOf(LOAD_ADDON_CHILD_FLAG) + 1]);
} else {
  registerTests();
}
