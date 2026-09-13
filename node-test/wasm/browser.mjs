// Real Chromium acceptance for the generated WASI browser loaders.
//
// Configuration (all optional):
//   WASI_ARTIFACT_ROOT    directory holding the generated loaders and .wasm
//                         artifacts. Defaults to this package directory. The
//                         path is canonicalized with realpath, because Vite's
//                         fs.allow must match the real path (on macOS /tmp is
//                         a symlink into /private/tmp and a mismatch makes bare
//                         module imports fail with an unrelated error).
//   PLAYWRIGHT_MODULE     path to an installed playwright-core entry point
//   CHROME_EXECUTABLE     Chrome/Chromium binary (otherwise channel "chrome")
//   WASI_BROWSER_FLAVORS  comma separated flavors to exercise,
//                         default "threads,wasip1"
//   WASI_BROWSER_DEADLINE_MS
//                         parent-side watchdog for the whole run, default
//                         300000. `page.setDefaultTimeout` does not bound
//                         `page.evaluate`, so a stalled wasm call would hang
//                         the harness forever without it.
//
// The threaded flavor (`wasm32-wasi`) is served with COOP/COEP: its shared
// memory needs cross-origin isolation. The threadless flavor
// (`wasm32-wasip1`) is served *without* those headers to prove it runs
// unisolated, and it never touches a worker.
//
// The deferred (workerd-safe) loader is exercised with a precompiled
// WebAssembly.Module built inside the page. That is deliberately limited
// coverage: compiling bytes is what a browser allows and workerd does not, so
// this validates the loader's module handling and lifecycle, not a workerd
// deployment (no workerd is available here).
import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createServer } from "../../website/node_modules/vite/dist/node/index.js";

const require = createRequire(import.meta.url);
const playwrightModule = process.env.PLAYWRIGHT_MODULE || require.resolve("playwright-core");
const { chromium } = await import(pathToFileURL(playwrightModule).href);

const artifactRoot = fs.realpathSync(
  process.env.WASI_ARTIFACT_ROOT || fileURLToPath(new URL("../", import.meta.url)),
);
const workspaceRoot = path.dirname(artifactRoot);
const flavors = (process.env.WASI_BROWSER_FLAVORS || "threads,wasip1")
  .split(",")
  .map((flavor) => flavor.trim())
  .filter(Boolean);

function realDirectories(...directories) {
  const resolved = new Set();
  for (const directory of directories) {
    try {
      resolved.add(fs.realpathSync(directory));
    } catch {}
  }
  return [...resolved];
}

const fsAllow = realDirectories(
  artifactRoot,
  workspaceRoot,
  path.join(artifactRoot, "node_modules"),
  path.join(workspaceRoot, "node_modules"),
);

function createAcceptanceServer(isolated) {
  return createServer({
    configFile: false,
    root: artifactRoot,
    logLevel: "warn",
    server: {
      host: "127.0.0.1",
      port: 0,
      fs: { allow: fsAllow },
      ...(isolated
        ? {
            headers: {
              "Cross-Origin-Opener-Policy": "same-origin",
              "Cross-Origin-Embedder-Policy": "require-corp",
            },
          }
        : {}),
    },
    optimizeDeps: {
      // Pre-bundle every bare import of the generated loaders: a dependency
      // Vite discovers mid-run reloads the page and invalidates the page state
      // the checks below rely on.
      include: ["@napi-rs/wasm-runtime", "@napi-rs/wasm-runtime/fs", "@emnapi/runtime"],
    },
  });
}

/** The loader files a flavor needs, named `<binary>.<suffix>-browser.js`. */
function flavorLoaders(suffix, binaries) {
  return binaries.map((binary) => path.join(artifactRoot, `${binary}.${suffix}-browser.js`));
}

const binaries = ["example", "async_tasks"];
const wantedFlavors = {
  threads: { suffix: "wasi", isolated: true },
  wasip1: { suffix: "wasip1", isolated: false },
};
for (const flavor of flavors) {
  const wanted = wantedFlavors[flavor];
  assert.ok(wanted, `unknown flavor ${flavor}; expected threads or wasip1`);
  for (const loader of flavorLoaders(wanted.suffix, binaries)) {
    assert.ok(fs.existsSync(loader), `missing generated loader ${loader}`);
  }
}

// A threadless build must not reference workers or a browser bundler, and the
// default generation has the optional fs/Buffer features disabled; the page run
// below exercises exactly that configuration.
if (flavors.includes("wasip1")) {
  for (const loader of flavorLoaders("wasip1", binaries)) {
    const source = fs.readFileSync(loader, "utf8");
    assert.doesNotMatch(source, /new Worker\(|wasi-worker/, `${loader} must not need a worker`);
    assert.doesNotMatch(
      source,
      /wasm-runtime\/fs|from "buffer"/,
      `${loader} must be generated without browser.fs/browser.buffer`,
    );
  }
}
if (flavors.includes("threads")) {
  for (const loader of flavorLoaders("wasi", binaries)) {
    assert.match(
      fs.readFileSync(loader, "utf8"),
      /new Worker\(/,
      `${loader} must pre-create the emnapi worker pool`,
    );
  }
}

// Vite 6+ `createServer` is asynchronous.
const isolatedServer = flavors.includes("threads") ? await createAcceptanceServer(true) : undefined;
const plainServer = flavors.some((flavor) => !wantedFlavors[flavor].isolated)
  ? await createAcceptanceServer(false)
  : undefined;

let browser;
const summary = {};
const deadlineMs = Number(process.env.WASI_BROWSER_DEADLINE_MS ?? 300_000);
// The watchdog only fires when the run exceeded its budget; it exits loudly
// instead of leaving a hung browser behind, and never masks a completed run.
const watchdog = setTimeout(() => {
  console.error(
    `browser acceptance exceeded ${deadlineMs} ms; a wasm stall cannot be interrupted from the page`,
  );
  process.exit(1);
}, deadlineMs);
watchdog.unref();
try {
  await isolatedServer?.listen();
  await plainServer?.listen();
  browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_EXECUTABLE
      ? { executablePath: process.env.CHROME_EXECUTABLE }
      : { channel: "chrome" }),
  });
  summary.browser = browser.version();

  const openPage = async (server) => {
    const page = await browser.newPage();
    page.setDefaultTimeout(60_000);
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/wasm/index.html`);
    return { page, errors };
  };

  if (isolatedServer) {
    const { page, errors } = await openPage(isolatedServer);
    summary.threads = await page.evaluate(async () => {
      const check = (condition, message) => {
        if (!condition) throw new Error(message);
      };
      check(crossOriginIsolated, "the threaded flavor requires cross-origin isolation");
      const example = (await import("/example.wasi-browser.js")).default;
      const tasks = (await import("/async_tasks.wasi-browser.js")).default;
      check(example.add(2, 3) === 5, "sync export");
      check(example.roundtripStr("WASM 中文 🚀") === "WASM 中文 🚀", "UTF-8");
      check(
        JSON.stringify(example.u8ArrayToArray(new Uint8Array([1, 2, 3]))) === "[1,2,3]",
        "typed array input",
      );
      check((await example.asyncPlus100(7)) === 107, "single async");
      check((await tasks.asyncThreadValue(7)) === 8, "threaded async");
      let events = 0;
      check(
        (await tasks.asyncSliceEvents(1024, (event) => {
          check(event.index === events, "event ordering");
          check(event.text === `event-${events}`, "event deep capture");
          events++;
        })) === 1024,
        "progress result",
      );
      check(events === 1024, "progress delivery");
      const reason = { browser: "primitive rejection ownership" };
      const thrown = await tasks
        .asyncThrowingEvents(1, () => {
          throw reason;
        })
        .then(
          () => null,
          (error) => error,
        );
      check(thrown === reason, "listener rejection identity");
      const concurrent = await Promise.all(
        Array.from({ length: 32 }, (_, index) => tasks.asyncThreadValue(index)),
      );
      check(
        concurrent.every((value, index) => value === index + 1),
        "concurrent async",
      );
      const controller = new AbortController();
      const cancelled = tasks.asyncAbortable(200000000, controller.signal).then(
        () => false,
        () => true,
      );
      controller.abort();
      check(await cancelled, "abort rejects");
      const disposeSymbol = Symbol.for("napi.rs.wasi.dispose");
      check(typeof example[disposeSymbol] === "function", "the loader must publish dispose");
      await example[disposeSymbol]();
      await tasks[disposeSymbol]();
      return {
        sync: true,
        utf8: true,
        typedArray: true,
        singleAsync: true,
        threadedAsync: true,
        events,
        listenerIdentity: true,
        concurrent: 32,
        abort: true,
        disposed: true,
      };
    });
    assert.deepEqual(errors, [], "the threaded page must not raise");
    await page.close();
  }

  if (plainServer) {
    const { page, errors } = await openPage(plainServer);
    summary.wasip1 = await page.evaluate(async () => {
      const check = (condition, message) => {
        if (!condition) throw new Error(message);
      };
      check(!crossOriginIsolated, "the threadless flavor must not need cross-origin isolation");
      const example = (await import("/example.wasip1-browser.js")).default;
      const tasks = (await import("/async_tasks.wasip1-browser.js")).default;
      check(example.add(2, 3) === 5, "sync export");
      check(example.roundtripStr("WASM 中文 🚀") === "WASM 中文 🚀", "UTF-8");
      check(
        JSON.stringify(example.u8ArrayToArray(new Uint8Array([1, 2, 3]))) === "[1,2,3]",
        "typed array input",
      );
      check((await example.asyncPlus100(7)) === 107, "single async");

      // Async work is implemented inline on the event loop for this flavor, so
      // the `.thread` exports the threaded flavor uses are the interesting
      // path - 1024 ordered events is well past the old 256-entry queue bound.
      let events = 0;
      check(
        (await tasks.asyncSliceEvents(1024, (event) => {
          check(event.index === events, "threadless event ordering");
          check(event.text === `event-${events}`, "threadless event deep capture");
          events++;
        })) === 1024,
        "threadless progress result",
      );
      check(events === 1024, "threadless progress delivery");

      const reason = { browser: "threadless primitive rejection ownership" };
      const thrown = await tasks
        .asyncThrowingEvents(1, () => {
          throw reason;
        })
        .then(
          () => null,
          (error) => error,
        );
      check(thrown === reason, "threadless listener rejection identity");

      const controller = new AbortController();
      const cancelled = tasks.asyncAbortable(200000000, controller.signal).then(
        () => false,
        () => true,
      );
      controller.abort();
      check(await cancelled, "threadless abort rejects");

      // Cancelling from inside an event listener must reject the same way.
      const sliceController = new AbortController();
      let sliceEvents = 0;
      const sliceOutcome = await tasks
        .asyncAbortableSliceEvents(4096, sliceController.signal, () => {
          sliceEvents++;
          if (sliceEvents === 8) {
            sliceController.abort();
          }
        })
        .then(
          () => "resolved",
          () => "rejected",
        );
      check(sliceOutcome === "rejected", "threadless cancel from a listener rejects");

      const disposeSymbol = Symbol.for("napi.rs.wasi.dispose");
      await example[disposeSymbol]();
      await tasks[disposeSymbol]();
      return {
        sync: true,
        utf8: true,
        typedArray: true,
        singleAsync: true,
        threadedExports: true,
        events,
        listenerIdentity: true,
        abort: true,
        cancelFromListener: true,
        disposed: true,
      };
    });
    assert.deepEqual(errors, [], "the threadless page must not raise");

    // The deferred loader: precompiled module input, instance lifecycle and the
    // module-local singleton (limited to browser capabilities, see header).
    summary.deferred = await page.evaluate(async () => {
      const check = (condition, message) => {
        if (!condition) throw new Error(message);
      };
      const deferred = await import("/example.wasip1-deferred.js");
      const wasmUrl = async (name) => {
        for (const candidate of [
          `/${name}.wasm32-wasip1.wasm`,
          `/zig-out/node/${name}.wasm32-wasip1.wasm`,
        ]) {
          const response = await fetch(candidate);
          if (response.ok) return response.arrayBuffer();
        }
        throw new Error(`cannot fetch ${name}.wasm32-wasip1.wasm`);
      };
      const bytes = await wasmUrl("example");
      const module = await WebAssembly.compile(bytes);

      const rejected = await deferred.createInstance(bytes).then(
        () => null,
        (error) => error,
      );
      check(rejected instanceof TypeError, "the deferred loader must reject byte buffers");

      const instance = await deferred.createInstance(module);
      check(instance.exports.add(2, 3) === 5, "createInstance runs the addon");
      const other = await deferred.createInstance(module);
      check(other.exports !== instance.exports, "createInstance returns independent instances");
      await instance.dispose();
      await other.dispose();

      const singleton = await deferred.instantiate(module);
      check(singleton.add(4, 5) === 9, "instantiate runs the singleton");
      check((await deferred.instantiate(module)) === singleton, "instantiate shares one instance");
      await deferred.dispose();
      const recreated = await deferred.instantiate(module);
      check(recreated.add(1, 1) === 2, "instantiate recreates after dispose");
      await deferred.dispose();
      return {
        byteBufferRejected: true,
        independentInstances: true,
        singletonShared: true,
        reinstantiated: true,
      };
    });
    assert.deepEqual(errors, [], "the threadless page must not raise");
    await page.close();
  }

  console.log(JSON.stringify(summary));
} finally {
  clearTimeout(watchdog);
  await browser?.close();
  await isolatedServer?.close();
  await plainServer?.close();
}
