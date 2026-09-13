/**
 * End-to-end WASI validation through the *packed* CLI: `npm pack` the CLI,
 * extract the tarball (the package that would be installed), scaffold a
 * project with it, build a real wasm32-wasip1-threads addon with the real Zig
 * toolchain, and load the generated loader with the real emnapi runtime.
 *
 * No network is used: the extracted CLI resolves its dependencies from the
 * checkout, and the scaffold's runtime packages are linked from the repository
 * install (emnapi / @emnapi/core / @emnapi/runtime 2.0.0-alpha.5 and
 * @napi-rs/wasm-runtime 1.2.4).
 *
 * The build half needs the ABI work that links the emnapi v2 archives; the
 * assertions about the generated files do not. When the checkout does not have
 * the archive integration yet the test reports that precondition instead of
 * pretending to pass.
 */

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const packageDir = path.resolve(__dirname, "..");
const workspaceRoot = path.resolve(packageDir, "..", "..");
const scratchRoot = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-wasi-pack-"));

after(() => {
  fs.rmSync(scratchRoot, { recursive: true, force: true });
});

function run(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, {
    cwd: options.cwd ?? scratchRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
    timeout: options.timeout ?? 600_000,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, `${command}: ${result.stdout}\n${result.stderr}`);
  return result;
}

/**
 * The emnapi archive the build helper links. The ABI work replaced the removed
 * `libemnapi-basic-napi-rs-mt.a` with the v2 basic composition for a Zig build;
 * without it a real WASI build cannot link.
 */
function abiArchiveIntegrated() {
  const buildScript = path.join(workspaceRoot, "src", "build", "napi-build.zig");
  try {
    return fs.readFileSync(buildScript, "utf8").includes("libemnapi-basic-napi-rs.a");
  } catch {
    return false;
  }
}

/** Runtime packages of the repository install, for the scaffold's node_modules. */
function runtimePackagesRoot() {
  for (const candidate of [
    path.join(workspaceRoot, "node-test", "node_modules"),
    path.join(workspaceRoot, "node_modules"),
  ]) {
    if (fs.existsSync(path.join(candidate, "emnapi", "lib", "wasm32-wasip1"))) {
      return candidate;
    }
  }
  return undefined;
}

function extractPackedCli() {
  const packDir = path.join(scratchRoot, "pack");
  fs.mkdirSync(packDir, { recursive: true });
  run("npm", ["pack", "--pack-destination", packDir], { cwd: packageDir });
  const archive = fs.readdirSync(packDir).find((name) => name.endsWith(".tgz"));
  assert.ok(archive, "npm pack produced no tarball");
  const extractDir = path.join(scratchRoot, "installed");
  fs.mkdirSync(extractDir, { recursive: true });
  run("tar", ["-xzf", path.join(packDir, archive), "-C", extractDir]);
  const installed = path.join(extractDir, "package");
  assert.ok(
    fs.existsSync(path.join(installed, "zig", "build.zig")),
    "the pack must bundle the Zig sources",
  );
  // The installed package would have its dependencies next to it; linking the
  // checkout's install keeps the test offline.
  fs.symlinkSync(
    path.join(workspaceRoot, "node_modules"),
    path.join(installed, "node_modules"),
    "dir",
  );
  return path.join(installed, "bin", "zig-napi.js");
}

// Reported as a skip (not a silent pass) while the archive integration is
// missing, and it starts running the moment that lands.
const skipReason = abiArchiveIntegrated()
  ? undefined
  : "ABI archive integration pending: the checkout does not link the emnapi v2 basic archive yet";

test(
  "the packed CLI builds and loads a real threaded WASI addon",
  { timeout: 900_000, skip: skipReason },
  () => {
    const runtimeRoot = runtimePackagesRoot();
    assert.ok(
      runtimeRoot,
      "the repository install of emnapi 2.x / @napi-rs/wasm-runtime is missing",
    );

    const packedCli = extractPackedCli();
    const project = path.join(scratchRoot, "packed addon");
    run(process.execPath, [
      packedCli,
      "new",
      project,
      "--no-interactive",
      "--no-enable-default-targets",
      "--name",
      "packed-addon",
      "--addon",
      "packed_addon",
      "--targets",
      "wasm32-wasip1-threads",
    ]);
    // The scaffold resolves its runtime packages like an installed project would.
    fs.symlinkSync(runtimeRoot, path.join(project, "node_modules"), "dir");

    run(process.execPath, [
      packedCli,
      "build",
      "--cwd",
      project,
      "--target",
      "wasm32-wasip1-threads",
    ]);

    const wasmPath = path.join(project, "zig-out", "node", "packed_addon.wasm32-wasi.wasm");
    assert.ok(fs.existsSync(wasmPath), `${wasmPath} was not produced`);
    for (const fileName of [
      "packed_addon.wasi.cjs",
      "packed_addon.wasi.d.cts",
      "packed_addon.wasi-browser.js",
      "wasi-worker.mjs",
      "wasi-worker-browser.mjs",
      "browser.js",
    ]) {
      assert.ok(fs.existsSync(path.join(project, fileName)), `missing generated ${fileName}`);
    }

    // The module must carry the exports the JS side drives threads and teardown
    // through, and must not need unresolved pthread imports.
    const inspect = [
      'const fs = require("node:fs");',
      `const module = new WebAssembly.Module(fs.readFileSync(${JSON.stringify(wasmPath)}));`,
      "const exports = WebAssembly.Module.exports(module).map((entry) => entry.name);",
      "const imports = WebAssembly.Module.imports(module).map((entry) => entry.module + '.' + entry.name);",
      "process.stdout.write(JSON.stringify({ exports, imports }));",
    ].join("\n");
    const inspected = JSON.parse(run(process.execPath, ["-e", inspect]).stdout);
    for (const name of [
      "emnapi_async_worker_create",
      "emnapi_async_worker_init",
      "napi_register_wasm_v1",
    ]) {
      assert.ok(inspected.exports.includes(name), `the addon must export ${name}`);
    }
    assert.ok(
      inspected.imports.includes("env.memory"),
      `the addon must import its memory: ${inspected.imports.join(", ")}`,
    );
    assert.ok(
      !inspected.imports.some((entry) => /pthread_|__wasi_thread_spawn/.test(entry)),
      `a Zig build must not leave unresolved thread imports: ${inspected.imports.join(", ")}`,
    );

    // The generated loader must run the addon on the shared memory it allocates
    // and let the process exit on its own.
    const load = [
      'const addon = require("./packed_addon.wasi.cjs");',
      "if (addon.add(2, 3) !== 5) {",
      '  throw new Error("add returned " + addon.add(2, 3));',
      "}",
      'process.stdout.write("loaded");',
    ].join("\n");
    const loaded = run(process.execPath, ["-e", load], { cwd: project, timeout: 120_000 });
    assert.equal(loaded.stdout, "loaded");

    // Explicit disposal goes through the teardown handshake and still exits.
    const dispose = [
      'const addon = require("./packed_addon.wasi.cjs");',
      'const dispose = addon[Symbol.for("napi.rs.wasi.dispose")];',
      'dispose().then(() => process.stdout.write("disposed"));',
    ].join("\n");
    const disposed = run(process.execPath, ["-e", dispose], { cwd: project, timeout: 120_000 });
    assert.equal(disposed.stdout, "disposed");
  },
);
