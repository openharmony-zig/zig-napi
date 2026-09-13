/**
 * Regression tests for the generated WASI loaders, workers and the CLI
 * generation surface.
 *
 * The loaders are exercised with a stubbed `@napi-rs/wasm-runtime` /
 * `@emnapi/runtime` (the runtime boundary) while everything the CLI generates
 * runs for real: the actual generated files, real Node workers, real ESM
 * imports, real `node:wasi`, and the real teardown handshake hand-off.
 */

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const vm = require("node:vm");
const { after, test } = require("node:test");

const packageDir = path.resolve(__dirname, "..");
const cliPath = path.join(packageDir, "bin", "zig-napi.js");
const templates = require(path.join(packageDir, "bin", "wasi-templates.cjs"));

const scratchRoot = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-wasi-loader-"));
const scratchProjects = [];

after(() => {
  fs.rmSync(scratchRoot, { recursive: true, force: true });
});

/* ------------------------------------------------------------------ *
 * Fixture helpers
 * ------------------------------------------------------------------ */

/**
 * A `zig` stand-in: answers the fingerprint repair and the build-option probe,
 * records the arguments of every real build, and never compiles anything.
 */
function writeStubZig(directory, options = {}) {
  fs.mkdirSync(directory, { recursive: true });
  const logPath = path.join(directory, "zig-args.log");
  const buildSucceeds = options.buildSucceeds === true;
  const script = `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(
  ${JSON.stringify(logPath)},
  JSON.stringify({ args: args, emnapiLinkDir: process.env.EMNAPI_LINK_DIR }) + "\\n",
);
if (args.includes("--help") || args.includes("-h")) {
  const options = ["  -Doptimize=[enum]            Optimize mode"];
  process.stdout.write("Usage: zig build [steps] [options]\\n\\nProject-Specific Options:\\n" + options.join("\\n") + "\\n");
  process.exit(0);
}
if (${buildSucceeds}) {
  process.exit(0);
}
process.stderr.write("use this value: 0x0123456789abcdef\\n");
process.exit(1);
`;
  const zigPath = path.join(directory, "zig");
  fs.writeFileSync(zigPath, script);
  fs.chmodSync(zigPath, 0o755);
  return {
    directory,
    logPath,
    env: { ...process.env, PATH: `${directory}${path.delimiter}${process.env.PATH}` },
    readArgs() {
      if (!fs.existsSync(logPath)) return [];
      return fs
        .readFileSync(logPath, "utf8")
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line).args);
    },
    readEmnapiLinkDir() {
      if (!fs.existsSync(logPath)) return undefined;
      const entries = fs
        .readFileSync(logPath, "utf8")
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line));
      const withLinkDir = entries.filter((entry) => entry.emnapiLinkDir !== undefined);
      return withLinkDir.length > 0 ? withLinkDir[withLinkDir.length - 1].emnapiLinkDir : undefined;
    },
    clearArgs() {
      fs.rmSync(logPath, { force: true });
    },
    /** Last real build invocation (the `--help` option probe is filtered out). */
    lastBuildArgs() {
      const builds = this.readArgs().filter(
        (args) => args[0] === "build" && !args.includes("--help"),
      );
      return builds[builds.length - 1];
    },
  };
}

function runCli(args, options = {}) {
  return childProcess.spawnSync(process.execPath, [cliPath, ...args], {
    cwd: options.cwd ?? scratchRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
    timeout: 120_000,
  });
}

/** Runtime stub shared by the CJS and ESM flavors of the fixture runtime. */
function runtimeStubSource(format = "cjs") {
  const esmExports = `export {
  instantiateNapiModule,
  instantiateNapiModuleSync,
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  createOnMessage,
  getDefaultContext,
  WASI,
  MessageHandler,
};
`;
  const cjsExports = `exports.instantiateNapiModule = instantiateNapiModule;
exports.instantiateNapiModuleSync = instantiateNapiModuleSync;
exports.emnapiAsyncWorkPlugin = emnapiAsyncWorkPlugin;
exports.emnapiTSFNPlugin = emnapiTSFNPlugin;
exports.createOnMessage = createOnMessage;
exports.getDefaultContext = getDefaultContext;
exports.WASI = WASI;
exports.MessageHandler = MessageHandler;
`;
  const footer = format === "esm" ? esmExports : cjsExports;
  return `"use strict";
const calls = (globalThis.__wasiStub = globalThis.__wasiStub || { events: [], instantiations: [] });
// read at call time: ESM stubs stay loaded across a test that changes the setup
function config() {
  return JSON.parse(process.env.WASI_STUB_CONFIG || "{}");
}
let pendingTurns = config().pendingTurns ?? 0;

function record(event, detail) {
  calls.events.push(detail === undefined ? event : [event, detail]);
}

function makeInstanceExports() {
  const exports = {
    __napi_register__probe_binding: function () {
      record("register");
    },
    napi_prepare_wasm_env_cleanup: function () {
      record("prepare");
      calls.prepared = true;
    },
    napi_wasm_env_cleanup_pending: function () {
      record("pending");
      if (calls.forcePending || config().pendingForever) return 3;
      if (pendingTurns > 0) {
        pendingTurns -= 1;
        return 1;
      }
      return 0;
    },
  };
  if (config().missingHandshake) {
    delete exports.napi_prepare_wasm_env_cleanup;
    delete exports.napi_wasm_env_cleanup_pending;
  }
  return exports;
}

function makeFailure() {
  if (config().failWith === "string") return "primitive failure";
  if (config().failWith === "number") return 42;
  return new Error(config().failMessage || "stub instantiation failure");
}

function callOnCreateWorker(options) {
  if (!config().callOnCreateWorker || typeof options.onCreateWorker !== "function") {
    return;
  }
  const worker = options.onCreateWorker({ type: "thread", name: "probe" });
  // Instrument the real worker so the test observes the loader terminating it.
  const terminate = worker.terminate.bind(worker);
  worker.terminate = function () {
    record("workerTerminate");
    return terminate();
  };
  calls.worker = worker;
}

function instantiateSync(wasmInput, options) {
  calls.instantiations.push(options);
  record("instantiate");
  callOnCreateWorker(options);
  if (config().failInstantiate) {
    options.beforeInit?.({ instance: { exports: makeInstanceExports() }, module: {}, memory: undefined });
    record("instantiate:throw");
    throw makeFailure();
  }
  const instance = { exports: makeInstanceExports() };
  const importObject = { env: { envImport: 1 }, napi: { napiImport: 1 }, emnapi: { emnapiImport: 1 } };
  // emnapi keeps the mutated object unless the hook returns another one.
  const hookResult = options.overwriteImports ? options.overwriteImports(importObject) : importObject;
  const overwritten =
    typeof hookResult === "object" && hookResult !== null ? hookResult : importObject;
  calls.overwrittenImports = overwritten;
  options.beforeInit?.({ instance, module: {}, memory: overwritten.env.memory });
  return { instance, module: {}, napiModule: { exports: { add: (left, right) => left + right } } };
}

const instantiateNapiModuleSync = instantiateSync;
async function instantiateNapiModule(wasmInput, options) {
  record("instantiateAsync");
  calls.usedAsyncInstantiation = true;
  return instantiateSync(wasmInput, options);
}
const emnapiAsyncWorkPlugin = { name: "emnapi-async-work" };
const emnapiTSFNPlugin = { name: "emnapi-tsfn" };
function createOnMessage(fs) {
  return function (data) {
    record("onMessage", data);
  };
}
function getDefaultContext() {
  if (!calls.context) {
    calls.context = {
      features: {},
      destroy() {
        calls.events.push("destroy");
      },
      suppressDestroy() {
        calls.events.push("suppressDestroy");
      },
    };
  }
  return calls.context;
}
const WASI = class StubWASI {
  constructor(options) {
    this.options = options;
    calls.wasiOptions = options;
  }
};
const MessageHandler = class StubMessageHandler {
  constructor(options) {
    this.options = options;
  }
  handle(event) {
    const memory = event?.data?.wasmMemory;
    const result = this.options.onLoad?.({ wasmModule: event?.data?.wasmModule, wasmMemory: memory });
    globalThis.postMessage?.({
      type: "loaded",
      hasResult: result !== undefined,
      events: (calls.events || []).slice(),
      // Only structured-cloneable fields: the raw options carry functions.
      instantiation: (() => {
        const options = calls.instantiations?.[0] ?? {};
        return {
          childThread: options.childThread,
          asyncWorkPoolSize: options.asyncWorkPoolSize,
          plugins: (options.plugins ?? []).map((plugin) => plugin.name),
          memory: calls.overwrittenImports?.env?.memory ?? null,
        };
      })(),
    });
  }
};
${footer}
`;
}

function contextStubSource(format = "cjs") {
  const footer =
    format === "esm"
      ? `export { createContext, getDefaultContext };
`
      : `exports.createContext = createContext;
exports.getDefaultContext = getDefaultContext;
`;
  return `"use strict";
const calls = (globalThis.__wasiStub = globalThis.__wasiStub || { events: [], instantiations: [] });
function config() {
  return JSON.parse(process.env.WASI_STUB_CONFIG || "{}");
}
function createContext(options) {
  if (config().failCreateContext) {
    throw new Error("stub context failure");
  }
  const context = {
    options,
    features: {},
    destroyed: false,
    suppressed: false,
    destroy() {
      context.destroyed = true;
      calls.events.push("destroy");
      return config().asyncDestroy ? Promise.resolve() : undefined;
    },
    suppressDestroy() {
      context.suppressed = true;
      calls.events.push("suppressDestroy");
    },
  };
  if (typeof process === "object" && process !== null && typeof process.once === "function") {
    process.once("beforeExit", () => {
      if (!context.suppressed) context.destroy();
    });
  }
  calls.context = context;
  calls.events.push("createContext");
  return context;
}
function getDefaultContext() {
  return calls.context;
}
${footer}
`;
}

const STUB_EMNAPI_VERSION = "2.0.0-alpha.5";

function writePackageStub(projectDir, name, version, extra = {}) {
  const directory = path.join(projectDir, "node_modules", ...name.split("/"));
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(
    path.join(directory, "package.json"),
    JSON.stringify({ name, version, ...extra }, null, 2),
  );
  return directory;
}

function writeRuntimeStubs(projectDir, versions = {}) {
  // The CLI validates that the archive package and the JS runtime packages are
  // one release before it builds a WASI target.
  const emnapiDirectory = writePackageStub(
    projectDir,
    "emnapi",
    versions.emnapi ?? STUB_EMNAPI_VERSION,
  );
  fs.mkdirSync(path.join(emnapiDirectory, "lib", "wasm32-wasip1"), { recursive: true });
  writePackageStub(projectDir, "@emnapi/core", versions.core ?? STUB_EMNAPI_VERSION);

  const wasmRuntimeDir = path.join(projectDir, "node_modules", "@napi-rs", "wasm-runtime");
  fs.mkdirSync(wasmRuntimeDir, { recursive: true });
  fs.writeFileSync(
    path.join(wasmRuntimeDir, "package.json"),
    JSON.stringify({
      name: "@napi-rs/wasm-runtime",
      version: "0.0.0-stub",
      type: "module",
      main: "./index.cjs",
      exports: {
        ".": { require: "./index.cjs", import: "./index.mjs" },
        "./fs": { import: "./fs.mjs" },
      },
    }),
  );
  fs.writeFileSync(path.join(wasmRuntimeDir, "index.cjs"), runtimeStubSource("cjs"));
  fs.writeFileSync(path.join(wasmRuntimeDir, "index.mjs"), runtimeStubSource("esm"));
  fs.writeFileSync(
    path.join(wasmRuntimeDir, "fs.mjs"),
    `const calls = (globalThis.__wasiStub = globalThis.__wasiStub || { events: [] });
export function memfs() {
  globalThis.__wasiStub.events.push("memfs");
  return { fs: { stubFs: true }, vol: { stubVol: true } };
}
export const memfsExported = { stubFs: true };
export class Buffer extends Uint8Array {}
`,
  );
  const emnapiRuntimeDir = path.join(projectDir, "node_modules", "@emnapi", "runtime");
  fs.mkdirSync(emnapiRuntimeDir, { recursive: true });
  fs.writeFileSync(
    path.join(emnapiRuntimeDir, "package.json"),
    JSON.stringify({
      name: "@emnapi/runtime",
      version: versions.runtime ?? STUB_EMNAPI_VERSION,
      type: "module",
      main: "./index.cjs",
      exports: { ".": { require: "./index.cjs", import: "./index.mjs" } },
    }),
  );
  fs.writeFileSync(path.join(emnapiRuntimeDir, "index.cjs"), contextStubSource("cjs"));
  fs.writeFileSync(path.join(emnapiRuntimeDir, "index.mjs"), contextStubSource("esm"));
}

/**
 * Scaffolds a real project through the CLI and adds the runtime stubs plus a
 * placeholder `.wasm` for every flavor it generated.
 */
function createProject(name, options = {}) {
  const projectDir = path.join(scratchRoot, name);
  const zig = writeStubZig(path.join(scratchRoot, `${name}-zig`), {
    buildSucceeds: options.buildSucceeds !== false,
  });
  const targets = options.targets ?? ["wasm32-wasip1-threads"];
  const args = [
    "new",
    projectDir,
    "--no-interactive",
    "--name",
    options.packageName ?? name,
    "--addon",
    options.binaryName ?? "probe_addon",
    "--targets",
    targets.join(","),
  ];
  if (options.enableDefaultTargets !== true) {
    args.splice(3, 0, "--no-enable-default-targets");
  }
  const result = runCli(args, { env: zig.env });
  assert.equal(result.status, 0, `scaffold failed: ${result.stdout}\n${result.stderr}`);
  scratchProjects.push(projectDir);
  writeRuntimeStubs(projectDir, options.runtimeVersions);
  const packageJson = JSON.parse(fs.readFileSync(path.join(projectDir, "package.json"), "utf8"));
  if (options.wasm) {
    packageJson.napi = { ...packageJson.napi, wasm: options.wasm };
  }
  fs.writeFileSync(path.join(projectDir, "package.json"), JSON.stringify(packageJson, null, 2));
  // The scaffold generated its loaders before the test configured `napi.wasm`,
  // so regenerate them through the same code path a build uses.
  if (options.regenerate !== false) {
    const regenerate = runCli(["build", "--cwd", projectDir, "--target", targets[0]], {
      env: zig.env,
    });
    assert.equal(regenerate.status, 0, `regeneration failed: ${regenerate.stderr}`);
    zig.clearArgs();
  }
  return {
    projectDir,
    zig,
    binaryName: options.binaryName ?? "probe_addon",
    packageName: options.packageName ?? name,
    flavor: options.flavor ?? { suffix: "wasi", platformArchABI: "wasm32-wasi" },
    file: (suffix) => path.join(projectDir, suffix),
  };
}

function writePlaceholderWasm(project, platformArchABI) {
  const wasmPath = path.join(project.projectDir, `${project.binaryName}.${platformArchABI}.wasm`);
  fs.writeFileSync(wasmPath, Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]));
  return wasmPath;
}

function loadStubEvents() {
  return {
    events: (globalThis.__wasiStub?.events ?? []).map((event) =>
      Array.isArray(event) ? event[0] : event,
    ),
    raw: globalThis.__wasiStub,
  };
}

function resetStubRuntime() {
  delete globalThis.__wasiStub;
}

/** Seeds the runtime stub before the loader loads it (e.g. to force a state). */
function seedStubRuntime(initial = {}) {
  globalThis.__wasiStub = { events: [], instantiations: [], ...initial };
}

function spawnNode(code, options = {}) {
  const args = options.esm ? ["--input-type=module", "-e", code] : ["-e", code];
  return childProcess.spawnSync(process.execPath, args, {
    cwd: options.cwd ?? scratchRoot,
    env: { ...process.env, ...options.env },
    encoding: "utf8",
    timeout: 60_000,
  });
}

/**
 * Waits for an asynchronous loader-side transition (rollbacks settle off the
 * require call stack). Bounded, so a missing transition fails instead of
 * hanging.
 */
async function waitFor(predicate, description, turns = 400) {
  for (let turn = 0; turn < turns; turn += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail(`timed out waiting for ${description}`);
}

/* ------------------------------------------------------------------ *
 * Flavor model
 * ------------------------------------------------------------------ */

test("WASI target spellings map to flavors, platformArchABI and loader stems", () => {
  assert.deepEqual(
    templates.collectWasiFlavors([
      "aarch64-apple-darwin",
      "wasm32-wasip1",
      "wasm32-wasip1-threads",
      "wasm32-wasi",
      "wasm32-wasi-preview1-threads",
      "wasm32-wasip1",
    ]),
    [
      {
        canonicalTriple: "wasm32-wasip1-threads",
        platformArchABI: "wasm32-wasi",
        loaderSuffix: "wasi",
        threads: true,
      },
      {
        canonicalTriple: "wasm32-wasip1",
        platformArchABI: "wasm32-wasip1",
        loaderSuffix: "wasip1",
        threads: false,
      },
    ],
  );
  // `wasm32-wasi` is the historical threaded spelling and must never be
  // inferred threadless from its name.
  assert.equal(templates.isWasiThreadsTargetName("wasm32-wasi"), true);
  assert.equal(templates.isWasiThreadsTargetName("wasm32-wasip1"), false);
  assert.equal(templates.isWasiTargetName("aarch64-apple-darwin"), false);
  assert.equal(
    templates.normalizeWasiTargetName("wasm32-wasi-preview1-threads"),
    "wasm32-wasip1-threads",
  );
  assert.equal(templates.normalizeWasiTargetName("x86_64-apple-darwin"), "x86_64-apple-darwin");
  assert.equal(templates.wasiLoaderSuffix("wasm32-wasi"), "wasi");
  assert.equal(templates.wasiLoaderSuffix("wasm32-wasip1"), "wasip1");
  assert.equal(
    templates.optionalPackageName("probe-addon", "wasm32-wasi"),
    "probe-addon-wasm32-wasi",
  );
  assert.equal(
    templates.optionalPackageName("@scope/probe", "wasm32-wasip1"),
    "@scope/probe-wasm32-wasip1",
  );
});

test("napi.wasm configuration is validated before anything is generated", () => {
  assert.deepEqual(templates.resolveWasmConfig({}), {
    initialMemory: 4000,
    maximumMemory: 65536,
    browser: { fs: false, asyncInit: false, buffer: false, errorEvent: false },
  });
  assert.deepEqual(templates.wasiMemoryBuildArgs({ wasm: {} }), []);
  assert.deepEqual(
    templates.wasiMemoryBuildArgs({ wasm: { initialMemory: 1024, maximumMemory: 2048 } }),
    ["-Dwasi-initial-memory-pages=1024", "-Dwasi-max-memory-pages=2048"],
  );

  const invalidCases = [
    [{ wasm: { initialMemory: 0 } }, /initialMemory must be between 1 and 65536/],
    [{ wasm: { initialMemory: 65537 } }, /initialMemory must be between 1 and 65536/],
    [{ wasm: { initialMemory: 1.5 } }, /must be an integer number of wasm pages/],
    [
      { wasm: { initialMemory: 2048, maximumMemory: 1024 } },
      /must not exceed napi.wasm.maximumMemory/,
    ],
    [
      { wasm: { initialMemory: 128 } },
      /needs at least 256 pages \(16777216 bytes\) because the Zig linker reserves a 16 MiB stack/,
    ],
    [
      { wasm: { initialMemory: 2048, maximumMemory: 2048 } },
      /leaves no room to grow; the Zig\/wasi-libc allocator grows linear memory/,
    ],
    [{ wasm: { browser: { fs: "yes" } } }, /browser.fs must be a boolean/],
    [{ wasm: "wasm32" }, /napi.wasm must be an object/],
  ];
  for (const [config, pattern] of invalidCases) {
    assert.throws(() => templates.resolveWasmConfig(config), pattern);
  }
});

test("every generated module parses", () => {
  const generated = {
    "threaded-node.cjs": templates.createWasiNodeBinding({
      wasmFileName: "probe.wasm32-wasi",
      packageName: "probe",
      platformArchABI: "wasm32-wasi",
      threads: true,
    }),
    "single-node.cjs": templates.createWasiNodeBinding({
      wasmFileName: "probe.wasm32-wasip1",
      packageName: "probe",
      platformArchABI: "wasm32-wasip1",
      threads: false,
    }),
    "worker.mjs": templates.WASI_WORKER_TEMPLATE,
    "browser-worker.mjs": templates.createWasiBrowserWorkerBinding(true, true),
    "browser.mjs": templates.createWasiBrowserBinding({
      wasmFileName: "probe.wasm32-wasi",
      threads: true,
    }),
    "browser-single.mjs": templates.createWasiBrowserBinding({
      wasmFileName: "probe.wasm32-wasip1",
      threads: false,
      fs: true,
      asyncInit: true,
      buffer: true,
      errorEvent: true,
    }),
    "deferred.mjs": templates.createWasiDeferredBrowserBinding({
      wasmFileName: "probe.wasm32-wasip1",
    }),
  };
  const directory = fs.mkdtempSync(path.join(scratchRoot, "parse-"));
  for (const [fileName, source] of Object.entries(generated)) {
    const filePath = path.join(directory, fileName);
    fs.writeFileSync(filePath, source);
    if (fileName.endsWith(".cjs")) {
      new vm.Script(source, { filename: fileName });
      continue;
    }
    const result = childProcess.spawnSync(process.execPath, ["--check", filePath], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, `${fileName}: ${result.stderr}`);
  }
});

test("loaders declare the emnapi plugins, handshake and flavor-specific memory", () => {
  const threaded = templates.createWasiNodeBinding({
    wasmFileName: "probe.wasm32-wasi",
    packageName: "probe",
    platformArchABI: "wasm32-wasi",
    threads: true,
  });
  const single = templates.createWasiNodeBinding({
    wasmFileName: "probe.wasm32-wasip1",
    packageName: "probe",
    platformArchABI: "wasm32-wasip1",
    threads: false,
  });

  for (const source of [threaded, single]) {
    assert.match(source, /plugins: \[__emnapiAsyncWorkPlugin, __emnapiTSFNPlugin\]/);
    assert.match(source, /napi_prepare_wasm_env_cleanup/);
    assert.match(source, /napi_wasm_env_cleanup_pending/);
    assert.match(source, /ERR_NAPI_WASI_CLEANUP_PENDING/);
    assert.match(source, /require\("@emnapi\/runtime"\)/);
    // A previous implementation patched private Node.js worker symbols to keep
    // the process alive; unref() is the documented mechanism.
    assert.doesNotMatch(source, /kPublicPort|kHandle|getOwnPropertySymbols/);
  }
  assert.match(threaded, /shared: true/);
  assert.match(threaded, /reuseWorker: true/);
  assert.match(threaded, /worker\.unref\(\)/);
  assert.doesNotMatch(single, /shared: true/);
  assert.match(single, /asyncWorkPoolSize: 0/);
  assert.doesNotMatch(single, /new Worker\(/);

  const browserThreaded = templates.createWasiBrowserBinding({
    wasmFileName: "probe.wasm32-wasi",
    threads: true,
  });
  const browserSingle = templates.createWasiBrowserBinding({
    wasmFileName: "probe.wasm32-wasip1",
    threads: false,
  });
  assert.match(browserThreaded, /reuseWorker: \{ size: __asyncWorkPoolSize \+ __workerPoolSize \}/);
  assert.match(browserThreaded, /hardwareConcurrency/);
  assert.match(browserThreaded, /shared: true/);
  assert.match(browserSingle, /asyncWorkPoolSize: 0/);
  assert.doesNotMatch(browserSingle, /shared: true/);
  // Threaded browser builds must initialize asynchronously: the reuse pool is
  // created asynchronously and the module cannot be instantiated before it.
  assert.match(browserThreaded, /await __emnapiInstantiateNapiModule\(__wasmFile/);
  assert.match(browserSingle, /__emnapiInstantiateNapiModuleSync\(__wasmFile/);
  // Threadless browser builds need no worker scripts at all.
  assert.doesNotMatch(browserSingle, /wasi-worker-browser\.mjs/);
});

test("browser options reach the generated loaders and workers", () => {
  const browserFs = templates.createWasiBrowserBinding({
    wasmFileName: "probe.wasm32-wasi",
    threads: true,
    fs: true,
    buffer: true,
    errorEvent: true,
  });
  assert.match(browserFs, /import \{ memfs, Buffer \} from "@napi-rs\/wasm-runtime\/fs"/);
  assert.match(browserFs, /fs: __fs,/);
  assert.match(browserFs, /__emnapiContext\.features\.Buffer = Buffer;/);
  assert.match(browserFs, /napi-rs-worker-error/);
  assert.match(browserFs, /__wasmCreateOnMessageForFsProxy\(__fs\)/);

  const browserBufferOnly = templates.createWasiBrowserBinding({
    wasmFileName: "probe.wasm32-wasip1",
    threads: false,
    buffer: true,
  });
  assert.match(browserBufferOnly, /import \{ Buffer \} from "buffer";/);
  assert.doesNotMatch(browserBufferOnly, /wasm-runtime\/fs/);

  const workerFs = templates.createWasiBrowserWorkerBinding(true, true);
  assert.match(workerFs, /createFsProxy\(__memfsExported\)/);
  assert.match(workerFs, /errorOutputs\.push\(\[\.\.\.arguments\]\)/);
  assert.match(workerFs, /postMessage\(\{ type: "error", error, errorOutputs \}\)/);
  assert.match(workerFs, /plugins: \[emnapiAsyncWorkPlugin, emnapiTSFNPlugin\]/);
  assert.match(workerFs, /preopens: \{\s*"\/": "\/",/);

  const workerPlain = templates.createWasiBrowserWorkerBinding(false, false);
  assert.doesNotMatch(workerPlain, /memfs/);
  assert.doesNotMatch(workerPlain, /errorOutputs/);
  assert.match(workerPlain, /plugins: \[emnapiAsyncWorkPlugin, emnapiTSFNPlugin\]/);
});

/* ------------------------------------------------------------------ *
 * CLI generation
 * ------------------------------------------------------------------ */

test("the CLI generates the artifact set every supported flavor needs", () => {
  const project = createProject("both-flavors", {
    targets: ["wasm32-wasip1-threads", "wasm32-wasip1"],
    packageName: "@scope/both-flavors",
    binaryName: "probe_addon",
  });
  const expectedFiles = [
    // threaded flavor keeps the historical `wasi` stem
    "probe_addon.wasi.cjs",
    "probe_addon.wasi.d.cts",
    "probe_addon.wasi-browser.js",
    "wasi-worker.mjs",
    "wasi-worker-browser.mjs",
    // threadless flavor
    "probe_addon.wasip1.cjs",
    "probe_addon.wasip1.d.cts",
    "probe_addon.wasip1-browser.js",
    "probe_addon.wasip1-deferred.js",
    "probe_addon.wasip1-deferred.d.ts",
    "browser.js",
  ];
  for (const fileName of expectedFiles) {
    assert.ok(fs.existsSync(path.join(project.projectDir, fileName)), `missing ${fileName}`);
  }

  const browserEntry = fs.readFileSync(path.join(project.projectDir, "browser.js"), "utf8");
  // The threadless flavor is preferred for the browser entry: it needs no
  // cross-origin isolation.
  assert.match(browserEntry, /"@scope\/both-flavors-wasm32-wasip1"/);

  assert.match(
    fs.readFileSync(path.join(project.projectDir, "probe_addon.wasi.cjs"), "utf8"),
    /probe_addon\.wasm32-wasi\.wasm/,
  );
  assert.match(
    fs.readFileSync(path.join(project.projectDir, "probe_addon.wasip1.cjs"), "utf8"),
    /probe_addon\.wasm32-wasip1\.wasm/,
  );
  assert.match(
    fs.readFileSync(path.join(project.projectDir, "probe_addon.wasip1-deferred.js"), "utf8"),
    /probe_addon\.wasm32-wasip1\.wasm/,
  );

  const packageJson = JSON.parse(
    fs.readFileSync(path.join(project.projectDir, "package.json"), "utf8"),
  );
  for (const glob of [
    "*.wasm",
    "*.d.cts",
    "*.wasi.cjs",
    "*.wasip1.cjs",
    "wasi-worker.mjs",
    "*-deferred.js",
  ]) {
    assert.ok(packageJson.files.includes(glob), `package.json files is missing ${glob}`);
  }
  assert.equal(packageJson.browser, "browser.js");
});

test("a native-only scaffold carries no WASI loader files", () => {
  const project = createProject("native-only", {
    targets: ["aarch64-apple-darwin"],
    packageName: "native-only",
  });
  const entries = fs.readdirSync(project.projectDir);
  assert.deepEqual(
    entries.filter((entry) => /wasi|wasip1|browser\.js|wasi-worker/.test(entry)),
    [],
  );
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(project.projectDir, "package.json"), "utf8"),
  );
  assert.equal(packageJson.browser, undefined);
  assert.ok(!packageJson.files.some((file) => /wasi|wasm|deferred/.test(file)));
});

test("a native target plus a WASI target scaffolds both flavors' files", () => {
  // This is the invocation the packaged-CLI test uses: default targets stay
  // enabled and an extra `--targets` entry is appended.
  const project = createProject("mixed-targets", {
    targets: ["aarch64-apple-darwin", "wasm32-wasip1-threads"],
    packageName: "mixed-targets",
    enableDefaultTargets: true,
  });
  const entries = fs.readdirSync(project.projectDir);
  assert.ok(entries.includes("probe_addon.wasi.cjs"), entries.join(","));
  assert.ok(entries.includes("wasi-worker.mjs"), entries.join(","));
  assert.ok(entries.includes("browser.js"), entries.join(","));
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(project.projectDir, "package.json"), "utf8"),
  );
  assert.ok(packageJson.napi.targets.includes("aarch64-apple-darwin"));
  assert.ok(packageJson.napi.targets.includes("wasm32-wasip1-threads"));
  assert.ok(packageJson.files.includes("*.wasi.cjs"));
  assert.ok(packageJson.files.includes("wasi-worker.mjs"));
});

test("the package entry picks the configured flavor and honours NAPI_RS_WASI_FLAVOR", () => {
  const project = createProject("entry-flavors", {
    targets: ["wasm32-wasip1"],
    packageName: "entry-flavors",
  });
  const entryPath = path.join(project.projectDir, "index.js");
  const wasiLoaderPath = path.join(project.projectDir, `${project.binaryName}.wasi.cjs`);
  const wasip1LoaderPath = path.join(project.projectDir, `${project.binaryName}.wasip1.cjs`);
  const loadEntry = () => {
    for (const candidate of [entryPath, wasiLoaderPath, wasip1LoaderPath]) {
      // `os.tmpdir()` and Node's resolved module paths differ on macOS
      // (/var vs /private/var), so clear by real path.
      if (fs.existsSync(candidate)) {
        delete require.cache[fs.realpathSync(candidate)];
      }
    }
    return require(entryPath);
  };

  fs.writeFileSync(wasip1LoaderPath, 'module.exports = { marker: "wasip1" };\n');
  assert.equal(loadEntry().marker, "wasip1", "the only generated flavor must be selected");

  fs.writeFileSync(wasiLoaderPath, 'module.exports = { marker: "wasi" };\n');
  assert.equal(loadEntry().marker, "wasi", "threaded is the declared first flavor");

  // NAPI_RS_WASI_FLAVOR selects exactly one flavor and never crosses over.
  process.env.NAPI_RS_WASI_FLAVOR = "wasm32-wasip1";
  try {
    assert.equal(loadEntry().marker, "wasip1");
  } finally {
    delete process.env.NAPI_RS_WASI_FLAVOR;
  }

  process.env.NAPI_RS_WASI_FLAVOR = "wasm32-wasm64";
  try {
    assert.throws(() => loadEntry(), /Unsupported WASI flavor wasm32-wasm64/);
  } finally {
    delete process.env.NAPI_RS_WASI_FLAVOR;
  }

  // The tri-state force flag keeps its documented meaning.
  fs.rmSync(wasiLoaderPath);
  fs.rmSync(wasip1LoaderPath);
  process.env.NAPI_RS_FORCE_WASI = "error";
  try {
    assert.throws(
      () => loadEntry(),
      (error) => {
        assert.match(
          error.message,
          /WASI binding not found and NAPI_RS_FORCE_WASI is set to error/,
        );
        assert.equal(error.cause?.code, "MODULE_NOT_FOUND");
        return true;
      },
    );
  } finally {
    delete process.env.NAPI_RS_FORCE_WASI;
  }

  // The strict flavor selection reports the flavor it could not find.
  process.env.NAPI_RS_WASI_FLAVOR = "wasm32-wasi";
  try {
    assert.throws(() => loadEntry(), /WASI binding for flavor "wasm32-wasi" not found/);
  } finally {
    delete process.env.NAPI_RS_WASI_FLAVOR;
  }
});

test("the CLI maps WASI targets and memory configuration onto zig build flags", () => {
  const project = createProject("build-flags", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "build-flags",
    buildSucceeds: true,
  });
  // the scaffold itself ran one `zig build` for the fingerprint repair
  project.zig.clearArgs();

  const threaded = runCli(
    ["build", "--cwd", project.projectDir, "--target", "wasm32-wasip1-threads"],
    {
      env: project.zig.env,
    },
  );
  assert.equal(threaded.status, 0, threaded.stderr);
  const threadedArgs = project.zig.lastBuildArgs();
  assert.ok(threadedArgs.includes("-Dtarget=wasm32-wasi"), `got ${threadedArgs.join(" ")}`);
  assert.ok(
    threadedArgs.includes("-Dcpu=baseline+atomics+bulk_memory+mutable_globals"),
    `got ${threadedArgs.join(" ")}`,
  );

  const single = runCli(["build", "--cwd", project.projectDir, "--target", "wasm32-wasip1"], {
    env: project.zig.env,
  });
  assert.equal(single.status, 0, single.stderr);
  const singleArgs = project.zig.lastBuildArgs();
  assert.ok(singleArgs.includes("-Dtarget=wasm32-wasi"), `got ${singleArgs.join(" ")}`);
  assert.ok(
    !singleArgs.some((arg) => arg.startsWith("-Dcpu=")),
    `threadless builds must not enable atomics: ${singleArgs.join(" ")}`,
  );
  // The archive is resolved from the project and passed through the
  // environment setting the build helper reads, so a hoisted install and a
  // nested one cannot disagree about which emnapi release is linked.
  assert.equal(
    project.zig.readEmnapiLinkDir(),
    fs.realpathSync(path.join(project.projectDir, "node_modules", "emnapi", "lib")),
  );
});

test("a WASI build refuses a mismatched emnapi install instead of linking it", () => {
  const project = createProject("emnapi-mismatch", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "emnapi-mismatch",
    buildSucceeds: true,
    runtimeVersions: { core: "2.0.0-alpha.4" },
    regenerate: false,
  });
  project.zig.clearArgs();
  const result = runCli(
    ["build", "--cwd", project.projectDir, "--target", "wasm32-wasip1-threads"],
    {
      env: project.zig.env,
    },
  );
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /emnapi version mismatch: emnapi@2\.0\.0-alpha\.5, @emnapi\/core@2\.0\.0-alpha\.4/,
  );
  assert.deepEqual(project.zig.lastBuildArgs(), undefined);
});

test("configured memory limits are passed to a build that declares them", () => {
  const project = createProject("memory-flags", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "memory-flags",
    buildSucceeds: true,
    wasm: { initialMemory: 1024, maximumMemory: 2048 },
  });
  project.zig.clearArgs();
  const result = runCli(
    ["build", "--cwd", project.projectDir, "--target", "wasm32-wasip1-threads"],
    {
      env: project.zig.env,
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const buildArgs = project.zig.lastBuildArgs();
  assert.ok(buildArgs.includes("-Dwasi-initial-memory-pages=1024"), `got ${buildArgs.join(" ")}`);
  assert.ok(buildArgs.includes("-Dwasi-max-memory-pages=2048"), `got ${buildArgs.join(" ")}`);

  const loader = fs.readFileSync(path.join(project.projectDir, "probe_addon.wasi.cjs"), "utf8");
  assert.match(loader, /initial: 1024/);
  assert.match(loader, /maximum: 2048/);

  // The defaults are not passed: the build helper derives the linker minimum
  // from the linked image, and the loader's default reservation stays 4000
  // pages.
  const defaults = createProject("memory-flags-defaults", {
    targets: ["wasm32-wasip1"],
    packageName: "memory-flags-defaults",
    buildSucceeds: true,
    wasm: { initialMemory: 1024, maximumMemory: 2048 },
  });
  fs.writeFileSync(
    path.join(defaults.projectDir, "package.json"),
    JSON.stringify(
      (() => {
        const packageJson = JSON.parse(
          fs.readFileSync(path.join(defaults.projectDir, "package.json"), "utf8"),
        );
        delete packageJson.napi.wasm;
        return packageJson;
      })(),
      null,
      2,
    ),
  );
  defaults.zig.clearArgs();
  const defaultsResult = runCli(
    ["build", "--cwd", defaults.projectDir, "--target", "wasm32-wasip1"],
    {
      env: defaults.zig.env,
    },
  );
  assert.equal(defaultsResult.status, 0, defaultsResult.stderr);
  const defaultsArgs = defaults.zig.lastBuildArgs();
  assert.ok(
    !defaultsArgs.some((arg) => arg.startsWith("-Dwasi-initial-memory-pages")),
    defaultsArgs.join(" "),
  );
  assert.ok(
    !defaultsArgs.some((arg) => arg.startsWith("-Dwasi-max-memory-pages")),
    defaultsArgs.join(" "),
  );
  assert.match(
    fs.readFileSync(path.join(defaults.projectDir, "probe_addon.wasip1.cjs"), "utf8"),
    /initial: 4000/,
  );
});

test("an invalid napi.wasm configuration fails the build instead of generating a broken loader", () => {
  const project = createProject("invalid-memory", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "invalid-memory",
    buildSucceeds: true,
    wasm: { initialMemory: 4096, maximumMemory: 1024 },
    regenerate: false,
  });
  project.zig.clearArgs();
  const result = runCli(
    ["build", "--cwd", project.projectDir, "--target", "wasm32-wasip1-threads"],
    {
      env: project.zig.env,
    },
  );
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /initialMemory \(4096\) must not exceed napi\.wasm\.maximumMemory \(1024\)/,
  );
  assert.deepEqual(
    project.zig.readArgs().filter((args) => args[0] === "build" && !args.includes("--help")),
    [],
  );
});

/* ------------------------------------------------------------------ *
 * Node loader behaviour
 * ------------------------------------------------------------------ */

const DISPOSE_SYMBOL = Symbol.for("napi.rs.wasi.dispose");

function requireGeneratedLoader(project, suffix = "wasi") {
  const loaderPath = path.join(project.projectDir, `${project.binaryName}.${suffix}.cjs`);
  delete require.cache[require.resolve(loaderPath)];
  return require(loaderPath);
}

function setStubConfig(config) {
  process.env.WASI_STUB_CONFIG = JSON.stringify(config);
  // Merged in place: an ESM loader keeps the stub object it imported, so
  // replacing it would leave the module writing into the old one.
  if (globalThis.__wasiStub) {
    globalThis.__wasiStub.events.length = 0;
    globalThis.__wasiStub.instantiations.length = 0;
    delete globalThis.__wasiStub.forcePending;
    delete globalThis.__wasiStub.context;
    delete globalThis.__wasiStub.worker;
    delete globalThis.__wasiStub.overwrittenImports;
    delete globalThis.__wasiStub.usedAsyncInstantiation;
    return;
  }
  resetStubRuntime();
}

test("the Node loader creates an isolated context and disposes it through the handshake", async () => {
  const project = createProject("node-threads-behaviour", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-threads-behaviour",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  const beforeExitListeners = process.listenerCount("beforeExit");
  setStubConfig({ pendingTurns: 1, callOnCreateWorker: true });
  process.env.NAPI_RS_ASYNC_WORK_POOL_SIZE = "6";

  const binding = requireGeneratedLoader(project);
  assert.equal(binding.add(2, 3), 5);

  // The emnapi auto-destroy listener emnapi 2.x registers from the context
  // constructor is removed again, so requiring the loader does not add a
  // process-wide beforeExit listener.
  assert.equal(process.listenerCount("beforeExit"), beforeExitListeners);
  assert.equal(typeof binding[DISPOSE_SYMBOL], "function");
  assert.ok(Object.getOwnPropertySymbols(binding).includes(DISPOSE_SYMBOL));

  const options = globalThis.__wasiStub.instantiations[0];
  assert.deepEqual(
    options.plugins.map((plugin) => plugin.name),
    ["emnapi-async-work", "emnapi-tsfn"],
  );
  assert.equal(options.asyncWorkPoolSize, 6);
  assert.equal(options.reuseWorker, true);
  assert.equal(typeof options.onCreateWorker, "function");
  assert.equal(options.context.suppressed, true);
  assert.equal(options.context.options.autoDestroy, false);
  assert.ok(options.__memory === undefined);
  assert.ok(
    globalThis.__wasiStub.overwrittenImports.env.memory.buffer instanceof SharedArrayBuffer,
    "the threaded loader must import a shared memory",
  );
  assert.equal(globalThis.__wasiStub.overwrittenImports.env.emnapiImport, 1);
  // registration hooks ran before the module was handed out
  assert.ok(loadStubEvents().events.includes("register"));

  await binding[DISPOSE_SYMBOL]();
  const events = loadStubEvents().events;
  const prepareIndex = events.indexOf("prepare");
  const firstPendingIndex = events.indexOf("pending");
  const destroyIndex = events.indexOf("destroy");
  const terminateIndex = events.indexOf("workerTerminate");
  assert.ok(prepareIndex !== -1 && firstPendingIndex > prepareIndex, `order: ${events.join(",")}`);
  assert.ok(destroyIndex > firstPendingIndex, `destroy must follow the drain: ${events.join(",")}`);
  assert.ok(
    terminateIndex > destroyIndex,
    `workers are terminated after the context: ${events.join(",")}`,
  );
  // the drain saw the queue empty, so the context was destroyed
  assert.equal(globalThis.__wasiStub.context.destroyed, true);
  // idempotent: a second disposal neither destroys nor terminates again
  const destroyCount = events.filter((event) => event === "destroy").length;
  await binding[DISPOSE_SYMBOL]();
  assert.equal(loadStubEvents().events.filter((event) => event === "destroy").length, destroyCount);
  delete process.env.NAPI_RS_ASYNC_WORK_POOL_SIZE;
});

test("a stuck settlement queue makes disposal retryable instead of destroying the context", async () => {
  const project = createProject("node-threads-retry", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-threads-retry",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  setStubConfig({});
  const binding = requireGeneratedLoader(project);
  globalThis.__wasiStub.forcePending = true;

  await assert.rejects(binding[DISPOSE_SYMBOL](), (error) => {
    assert.equal(error.code, "ERR_NAPI_WASI_CLEANUP_PENDING");
    assert.match(error.message, /still reports 3 queued settlement\(s\)/);
    return true;
  });
  assert.equal(globalThis.__wasiStub.context.destroyed, false);

  // The queue drains on the retry: disposal then destroys the context.
  globalThis.__wasiStub.forcePending = false;
  await binding[DISPOSE_SYMBOL]();
  assert.equal(globalThis.__wasiStub.context.destroyed, true);
});

test("initialization rollback destroys the context and preserves a primitive throw", async () => {
  const project = createProject("node-threads-rollback", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-threads-rollback",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  setStubConfig({ failInstantiate: true, failWith: "string" });
  const loaderPath = path.join(project.projectDir, `${project.binaryName}.wasi.cjs`);

  assert.throws(
    () => requireGeneratedLoader(project),
    (error) => error === "primitive failure",
  );
  const events = loadStubEvents().events;
  assert.ok(events.includes("prepare"), events.join(","));
  assert.ok(events.includes("destroy"), events.join(","));

  // The failed attempt is not retained: the next require starts over instead of
  // replaying a rollback record.
  delete require.cache[require.resolve(loaderPath)];
  assert.throws(
    () => require(loaderPath),
    (error) => error === "primitive failure",
  );
  assert.equal(process.listenerCount("exit"), 0);
});

test("a rollback that cannot reach its settlements is retained and replayed", async () => {
  const project = createProject("node-threads-rollback-retry", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-threads-rollback-retry",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  setStubConfig({ failInstantiate: true, failWith: "string" });
  const loaderPath = path.join(project.projectDir, `${project.binaryName}.wasi.cjs`);
  seedStubRuntime({ forcePending: true });

  let firstError;
  try {
    requireGeneratedLoader(project);
  } catch (error) {
    firstError = error;
  }
  // The primitive is preserved as the cause of the cleanup aggregate, and the
  // context was NOT destroyed over the still-queued settlement.
  assert.notEqual(firstError, undefined);
  assert.equal(firstError.cause ?? firstError, "primitive failure");
  assert.equal(globalThis.__wasiStub.context.destroyed, false);
  // The rollback settles off the require stack: it retains the context and
  // hands it to the process teardown only after the drain gave up.
  await waitFor(() => process.listenerCount("exit") === 1, "the retained rollback teardown");

  // Re-requiring the loader replays the retained rollback instead of
  // instantiating again; with the queue drained the replay destroys the context.
  globalThis.__wasiStub.forcePending = false;
  const createContextCount = loadStubEvents().events.filter(
    (event) => event === "createContext",
  ).length;
  delete require.cache[require.resolve(loaderPath)];
  assert.throws(() => require(loaderPath));
  await waitFor(() => globalThis.__wasiStub.context.destroyed, "the replayed rollback teardown");
  assert.equal(
    loadStubEvents().events.filter((event) => event === "createContext").length,
    createContextCount,
    "the replay must not create a second context",
  );
  await waitFor(() => process.listenerCount("exit") === 0, "the exit listener removal");
});

test("worker pool size from the environment is bounded and validated", () => {
  const project = createProject("node-pool-size", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-pool-size",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  const loaderPath = path.join(project.projectDir, `${project.binaryName}.wasi.cjs`);
  const probe = `
process.env.WASI_STUB_CONFIG = "{}";
const warnings = [];
process.on("warning", (warning) => warnings.push(warning.message));
require(${JSON.stringify(loaderPath)});
const size = globalThis.__wasiStub.instantiations[0].asyncWorkPoolSize;
setTimeout(() => {
  process.stdout.write(JSON.stringify({ size, warnings }));
}, 20);
`;
  const cases = [
    [undefined, 4, false],
    ["8", 8, false],
    ["0", 4, false],
    ["1.5", 4, true],
    ["-2", 4, true],
    ["Infinity", 4, true],
    ["1e9", 4, true],
    ["64", 64, false],
    // Each pooled worker instantiates the addon with its own memory, so the
    // pool is capped instead of echoing a four-digit threadpool size.
    ["1024", 4, true],
  ];
  for (const [value, expected, warns] of cases) {
    const result = spawnNode(probe, {
      cwd: project.projectDir,
      env: value === undefined ? {} : { NAPI_RS_ASYNC_WORK_POOL_SIZE: value },
    });
    assert.equal(result.status, 0, result.stderr);
    const parsed = JSON.parse(result.stdout);
    assert.equal(parsed.size, expected, `NAPI_RS_ASYNC_WORK_POOL_SIZE=${value}`);
    assert.equal(
      parsed.warnings.some((message) => message.includes("invalid worker pool size")),
      warns,
      `NAPI_RS_ASYNC_WORK_POOL_SIZE=${value}: ${parsed.warnings.join(" | ")}`,
    );
  }
});

test("a pooled worker never holds the Node.js process open", () => {
  const project = createProject("node-liveness", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-liveness",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  const loaderPath = path.join(project.projectDir, `${project.binaryName}.wasi.cjs`);
  const result = spawnNode(
    `
process.env.WASI_STUB_CONFIG = ${JSON.stringify(JSON.stringify({ callOnCreateWorker: true }))};
require(${JSON.stringify(loaderPath)});
if (!globalThis.__wasiStub.worker) {
  throw new Error("the loader did not create a worker");
}
process.stdout.write("loaded");
`,
    { cwd: project.projectDir },
  );
  assert.equal(
    result.error,
    undefined,
    `the process must exit on its own: ${result.error?.message}`,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "loaded");
});

/* ------------------------------------------------------------------ *
 * Worker scripts
 * ------------------------------------------------------------------ */

test("the Node worker instantiates as a child thread with the emnapi plugins", async () => {
  const project = createProject("node-worker", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "node-worker",
  });
  const worker = new (require("node:worker_threads").Worker)(
    path.join(project.projectDir, "wasi-worker.mjs"),
    {
      env: { ...process.env, WASI_STUB_CONFIG: "{}" },
    },
  );
  try {
    const message = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the worker never reported back")), 20_000);
      worker.once("message", (data) => {
        clearTimeout(timer);
        resolve(data);
      });
      worker.once("error", reject);
      // The worker forwards the raw message payload to its onmessage handler.
      worker.postMessage({ wasmModule: {}, wasmMemory: { stubMemory: true } });
    });
    assert.equal(message.type, "loaded");
    assert.equal(message.hasResult, true);
    const options = message.instantiation;
    assert.equal(options.childThread, true);
    assert.deepEqual(options.plugins, ["emnapi-async-work", "emnapi-tsfn"]);
    assert.equal(options.memory.stubMemory, true);
    // The worker's context comes from getDefaultContext() and is left to the
    // process teardown (suppressDestroy) rather than destroyed by the worker.
    assert.ok(message.events.includes("suppressDestroy"));
    assert.ok(!message.events.includes("destroy"));
  } finally {
    await worker.terminate();
  }
});

/* ------------------------------------------------------------------ *
 * Browser loaders (ESM)
 * ------------------------------------------------------------------ */

const BROWSER_FETCH_STUB = `
globalThis.fetch = async function (url) {
  const { readFileSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  try {
    const bytes = readFileSync(fileURLToPath(url));
    return {
      ok: true,
      status: 200,
      statusText: "OK",
      arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    };
  } catch {
    return { ok: false, status: 404, statusText: "Not Found", arrayBuffer: async () => new ArrayBuffer(0) };
  }
};
`;

function runBrowserProbe(project, body, env = {}) {
  return spawnNode(`${BROWSER_FETCH_STUB}${body}`, {
    esm: true,
    cwd: project.projectDir,
    env: { WASI_STUB_CONFIG: "{}", ...env },
  });
}

test("the threaded browser loader instantiates asynchronously with a reuse pool", () => {
  const project = createProject("browser-threads", {
    targets: ["wasm32-wasip1-threads"],
    packageName: "browser-threads",
  });
  writePlaceholderWasm(project, "wasm32-wasi");
  const result = runBrowserProbe(
    project,
    `
const module = await import("./probe_addon.wasi-browser.js");
const stub = globalThis.__wasiStub;
const options = stub.instantiations[0];
globalThis.onmessage = undefined;
const dispose = module.default[Symbol.for("napi.rs.wasi.dispose")];
await dispose();
const events = stub.events.map((event) => (Array.isArray(event) ? event[0] : event));
process.stdout.write(JSON.stringify({
  add: module.add(2, 3),
  defaultAdd: module.default.add(2, 3),
  shared: stub.overwrittenImports.env.memory.buffer instanceof SharedArrayBuffer,
  asyncWorkPoolSize: options.asyncWorkPoolSize,
  reuseWorker: options.reuseWorker,
  plugins: options.plugins.map((plugin) => plugin.name),
  asyncInstantiation: stub.usedAsyncInstantiation === true,
  destroyed: stub.context.destroyed,
  events,
}));
`,
  );
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.add, 5);
  assert.equal(parsed.defaultAdd, 5);
  assert.equal(parsed.shared, true);
  assert.equal(parsed.asyncWorkPoolSize, 4);
  assert.equal(
    parsed.asyncInstantiation,
    true,
    "a threaded browser build must instantiate asynchronously",
  );
  assert.equal(
    parsed.reuseWorker.size,
    parsed.asyncWorkPoolSize + (parsed.reuseWorker.size - parsed.asyncWorkPoolSize),
  );
  assert.ok(parsed.reuseWorker.size >= 6, `pool size ${parsed.reuseWorker.size}`);
  assert.deepEqual(parsed.plugins, ["emnapi-async-work", "emnapi-tsfn"]);
  assert.equal(parsed.destroyed, true);
  assert.ok(
    parsed.events.includes("prepare") && parsed.events.includes("destroy"),
    parsed.events.join(","),
  );
});

test("the threadless browser loader stays synchronous and unshared", () => {
  const project = createProject("browser-single", {
    targets: ["wasm32-wasip1"],
    packageName: "browser-single",
    wasm: { initialMemory: 1024, maximumMemory: 2048, browser: { fs: true, buffer: true } },
  });
  writePlaceholderWasm(project, "wasm32-wasip1");
  const result = runBrowserProbe(
    project,
    `
const module = await import("./probe_addon.wasip1-browser.js");
const stub = globalThis.__wasiStub;
const options = stub.instantiations[0];
const events = stub.events.map((event) => (Array.isArray(event) ? event[0] : event));
const memory = stub.overwrittenImports.env.memory;
const initialByteLength = memory.buffer.byteLength;
let grew = null;
let overflow = false;
try {
  grew = memory.grow(1024);
} catch (error) {
  grew = "failed: " + error.message;
}
try {
  memory.grow(1);
} catch {
  overflow = true;
}
process.stdout.write(JSON.stringify({
  add: module.add(2, 3),
  shared: memory.buffer instanceof SharedArrayBuffer,
  initialPages: 67108864 / 65536,
  byteLength: initialByteLength,
  grew,
  overflow,
  asyncWorkPoolSize: options.asyncWorkPoolSize,
  plugins: options.plugins.map((plugin) => plugin.name),
  asyncInstantiation: stub.usedAsyncInstantiation === true,
  memfs: events.includes("memfs"),
  bufferInjected: stub.context.features.Buffer !== undefined,
  wasiFs: stub.wasiOptions.fs.stubFs === true,
}));
`,
  );
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.add, 5);
  assert.equal(parsed.shared, false);
  assert.equal(
    parsed.asyncInstantiation,
    false,
    "threadless builds keep synchronous instantiation by default",
  );
  assert.equal(parsed.asyncWorkPoolSize, 0);
  assert.deepEqual(parsed.plugins, ["emnapi-async-work", "emnapi-tsfn"]);
  assert.equal(parsed.memfs, true, "browser.fs must mount memfs");
  assert.equal(parsed.wasiFs, true);
  assert.equal(parsed.bufferInjected, true, "browser.buffer must reach the emnapi context");
  assert.equal(parsed.byteLength, 1024 * 65536, "napi.wasm.initialMemory must size the memory");
  assert.equal(parsed.grew, 1024);
  assert.equal(parsed.overflow, true, "napi.wasm.maximumMemory must bound the memory");
});

test("asyncInit makes a threadless browser loader await the async instantiation", () => {
  const project = createProject("browser-async-init", {
    targets: ["wasm32-wasip1"],
    packageName: "browser-async-init",
    wasm: { browser: { asyncInit: true } },
  });
  writePlaceholderWasm(project, "wasm32-wasip1");
  const result = runBrowserProbe(
    project,
    `
const module = await import("./probe_addon.wasip1-browser.js");
const stub = globalThis.__wasiStub;
process.stdout.write(JSON.stringify({ add: module.add(1, 1), asyncInstantiation: stub.usedAsyncInstantiation === true }));
`,
  );
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.add, 2);
  assert.equal(parsed.asyncInstantiation, true);
});

test("a missing wasm artifact reports the fetch failure with the requested URL", () => {
  const project = createProject("browser-missing-wasm", {
    targets: ["wasm32-wasip1"],
    packageName: "browser-missing-wasm",
  });
  const result = runBrowserProbe(
    project,
    `
try {
  await import("./probe_addon.wasip1-browser.js");
  process.stdout.write(JSON.stringify({ threw: false }));
} catch (error) {
  process.stdout.write(JSON.stringify({ threw: true, message: error.message }));
}
`,
  );
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.threw, true);
  assert.match(parsed.message, /probe_addon\.wasm32-wasip1\.wasm/);
  assert.match(parsed.message, /404/);
});

/* ------------------------------------------------------------------ *
 * Deferred (workerd-safe) loader
 * ------------------------------------------------------------------ */

const EMPTY_WASM_MODULE_BYTES = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);

function deferredLoaderUrl(project) {
  return pathToFileURL(path.join(project.projectDir, `${project.binaryName}.wasip1-deferred.js`))
    .href;
}

test("the deferred loader rejects byte buffers and accepts precompiled modules", async () => {
  const project = createProject("deferred-basic", {
    targets: ["wasm32-wasip1"],
    packageName: "deferred-basic",
  });
  setStubConfig({ pendingTurns: 1 });
  const deferred = await import(deferredLoaderUrl(project));
  const module = new WebAssembly.Module(EMPTY_WASM_MODULE_BYTES);

  await assert.rejects(deferred.createInstance(EMPTY_WASM_MODULE_BYTES), (error) => {
    assert.ok(error instanceof TypeError);
    assert.match(error.message, /precompiled WebAssembly\.Module/);
    assert.match(error.message, /Cloudflare Workers disallows/);
    return true;
  });

  const instance = await deferred.createInstance(Promise.resolve(module));
  assert.equal(instance.exports.add(2, 3), 5);
  assert.equal(typeof instance.dispose, "function");
  const options = globalThis.__wasiStub.instantiations[0];
  assert.deepEqual(
    options.plugins.map((plugin) => plugin.name),
    ["emnapi-async-work", "emnapi-tsfn"],
  );
  assert.equal(options.asyncWorkPoolSize, 0);
  assert.equal(
    globalThis.__wasiStub.overwrittenImports.env.memory.buffer instanceof SharedArrayBuffer,
    false,
  );
  assert.equal(options.wasi.options.version, "preview1");
  assert.ok(loadStubEvents().events.includes("register"));

  await instance.dispose();
  const events = loadStubEvents().events;
  assert.ok(events.includes("prepare"), events.join(","));
  assert.ok(events.includes("destroy"), events.join(","));
});

test("the deferred loader singleton is shared, disposed, and recreated", async () => {
  const project = createProject("deferred-singleton", {
    targets: ["wasm32-wasip1"],
    packageName: "deferred-singleton",
  });
  setStubConfig({});
  const deferred = await import(deferredLoaderUrl(project));
  const module = new WebAssembly.Module(EMPTY_WASM_MODULE_BYTES);
  const otherModule = new WebAssembly.Module(EMPTY_WASM_MODULE_BYTES);

  const [first, second] = await Promise.all([
    deferred.instantiate(module),
    deferred.instantiate(module),
  ]);
  assert.equal(first, second);
  assert.equal(first.add(1, 2), 3);
  assert.equal(globalThis.__wasiStub.instantiations.length, 1, "one instance, one memory");

  await assert.rejects(
    deferred.instantiate(otherModule),
    /already owns a different WebAssembly\.Module/,
  );

  await deferred.dispose();
  assert.equal(globalThis.__wasiStub.context.destroyed, true);
  const afterDispose = await deferred.instantiate(otherModule);
  assert.equal(afterDispose.add(2, 2), 4);
  assert.equal(globalThis.__wasiStub.instantiations.length, 2);
  await deferred.dispose();
});

test("deferred instantiation failure rolls the context back and stays retryable", async () => {
  const project = createProject("deferred-rollback", {
    targets: ["wasm32-wasip1"],
    packageName: "deferred-rollback",
  });
  setStubConfig({ failInstantiate: true });
  const deferred = await import(deferredLoaderUrl(project));
  const module = new WebAssembly.Module(EMPTY_WASM_MODULE_BYTES);

  await assert.rejects(deferred.instantiate(module), /stub instantiation failure/);
  await waitFor(
    () => globalThis.__wasiStub.context.destroyed,
    "the rollback destroying the context",
  );

  // A singleton that failed can be created again on the next call.
  globalThis.__wasiStub.instantiations.length = 0;
  setStubConfig({});
  const exports = await deferred.instantiate(module);
  assert.equal(exports.add(3, 4), 7);
  await deferred.dispose();
});
