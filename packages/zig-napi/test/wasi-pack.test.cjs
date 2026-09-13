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
 * The build half needs the ABI work that links the emnapi v2 archives
 * (`src/build/napi-build.zig`): without it there is nothing to validate here,
 * so the missing integration fails the test instead of skipping it.
 */

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
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

/**
 * Runtime packages for the scaffold's `node_modules`. The `node-test` install
 * is the one that carries emnapi / @emnapi/core / @emnapi/runtime 2.0.0-alpha.5
 * with @napi-rs/wasm-runtime 1.2.4; the workspace root still links the 1.x
 * versions, which could not load the generated loaders at all.
 */
function runtimePackagesRoot() {
  for (const candidate of [
    path.join(workspaceRoot, "node-test", "node_modules"),
    path.join(workspaceRoot, "node_modules"),
  ]) {
    if (
      fs.existsSync(path.join(candidate, "emnapi", "lib", "wasm32-wasip1")) &&
      fs.existsSync(path.join(candidate, "@emnapi", "core", "package.json")) &&
      fs.existsSync(path.join(candidate, "@napi-rs", "wasm-runtime", "package.json"))
    ) {
      const version = JSON.parse(
        fs.readFileSync(path.join(candidate, "@emnapi", "core", "package.json"), "utf8"),
      ).version;
      assert.match(version, /^2\./, `the runtime packages must be emnapi 2.x, found ${version}`);
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
  // An installed package resolves its own dependencies from its own
  // `node_modules`, so link the CLI package's install (which has the 3.9.1
  // @napi-rs/cli this package depends on) rather than the workspace root.
  const cliDependencies = path.join(packageDir, "node_modules");
  assert.ok(
    fs.existsSync(cliDependencies),
    `the CLI package dependencies are not installed at ${cliDependencies}`,
  );
  assert.ok(
    fs.existsSync(path.join(cliDependencies, "@napi-rs", "cli", "package.json")),
    "the CLI package must have its own @napi-rs/cli install",
  );
  fs.symlinkSync(cliDependencies, path.join(installed, "node_modules"), "dir");
  return path.join(installed, "bin", "zig-napi.js");
}

test("the packed CLI builds and loads both real WASI flavors", { timeout: 900_000 }, () => {
  assert.ok(
    abiArchiveIntegrated(),
    "src/build/napi-build.zig does not link the emnapi v2 archive (libemnapi-basic-napi-rs.a), so a real WASI build cannot validate anything",
  );
  const runtimeRoot = runtimePackagesRoot();
  assert.ok(runtimeRoot, "the repository install of emnapi 2.x / @napi-rs/wasm-runtime is missing");

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
    "wasm32-wasip1-threads,wasm32-wasip1",
  ]);
  // The scaffold resolves its runtime packages like an installed project would.
  fs.symlinkSync(runtimeRoot, path.join(project, "node_modules"), "dir");

  const flavors = [
    {
      target: "wasm32-wasip1-threads",
      platformArchABI: "wasm32-wasi",
      suffix: "wasi",
      threads: true,
      extraFiles: ["wasi-worker.mjs", "wasi-worker-browser.mjs"],
    },
    {
      target: "wasm32-wasip1",
      platformArchABI: "wasm32-wasip1",
      suffix: "wasip1",
      threads: false,
      extraFiles: ["packed_addon.wasip1-deferred.js", "packed_addon.wasip1-deferred.d.ts"],
    },
  ];
  const builtWasmPaths = new Map();
  for (const flavor of flavors) {
    run(process.execPath, [packedCli, "build", "--cwd", project, "--target", flavor.target]);
    const wasmPath = path.join(
      project,
      "zig-out",
      "node",
      `packed_addon.${flavor.platformArchABI}.wasm`,
    );
    assert.ok(fs.existsSync(wasmPath), `${wasmPath} was not produced`);
    builtWasmPaths.set(flavor.suffix, wasmPath);
    for (const fileName of [
      `packed_addon.${flavor.suffix}.cjs`,
      `packed_addon.${flavor.suffix}.d.cts`,
      `packed_addon.${flavor.suffix}-browser.js`,
      ...flavor.extraFiles,
    ]) {
      assert.ok(fs.existsSync(path.join(project, fileName)), `missing generated ${fileName}`);
    }
  }
  // Building one flavor must not delete the other configured flavor's files.
  for (const flavor of flavors) {
    assert.ok(
      fs.existsSync(path.join(project, `packed_addon.${flavor.suffix}.cjs`)),
      `the ${flavor.suffix} loader was removed by the other flavor's build`,
    );
  }
  assert.ok(fs.existsSync(path.join(project, "browser.js")));

  // The module must carry the exports the JS side drives threads and teardown
  // through, and must not need unresolved pthread imports.
  const inspect = (wasmPath) =>
    [
      'const fs = require("node:fs");',
      `const module = new WebAssembly.Module(fs.readFileSync(${JSON.stringify(wasmPath)}));`,
      "const exports = WebAssembly.Module.exports(module).map((entry) => entry.name);",
      "const imports = WebAssembly.Module.imports(module).map((entry) => entry.module + '.' + entry.name);",
      "process.stdout.write(JSON.stringify({ exports, imports }));",
    ].join("\n");
  for (const flavor of flavors) {
    const inspected = JSON.parse(
      run(process.execPath, ["-e", inspect(builtWasmPaths.get(flavor.suffix))]).stdout,
    );
    // The worker-pool entry points exist only where a pool can exist: a
    // threadless build implements async work in the emnapi JS plugin on the
    // event loop and never spawns a wasm worker.
    const requiredExports = ["napi_register_wasm_v1", "emnapi_create_env", "emnapi_delete_env"];
    if (flavor.threads) {
      requiredExports.push("emnapi_async_worker_create", "emnapi_async_worker_init");
    }
    for (const name of requiredExports) {
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
  }

  // Each generated loader must run the addon on the memory it allocates, let
  // the process exit on its own, and support explicit disposal followed by a
  // fresh instance.
  for (const flavor of flavors) {
    const load = [
      `const loaderPath = "./packed_addon.${flavor.suffix}.cjs";`,
      `const suffix = ${JSON.stringify(flavor.suffix)};`,
      "const addon = require(loaderPath);",
      "if (addon.add(2, 3) !== 5) {",
      '  throw new Error(suffix + " add returned " + addon.add(2, 3));',
      "}",
      'if (!addon.hello().startsWith("hello from ")) {',
      '  throw new Error(suffix + " hello returned " + addon.hello());',
      "}",
      'const dispose = addon[Symbol.for("napi.rs.wasi.dispose")];',
      "dispose()",
      "  .then(() => {",
      "    delete require.cache[require.resolve(loaderPath)];",
      "    const reloaded = require(loaderPath);",
      "    if (reloaded.add(4, 5) !== 9) {",
      '      throw new Error("the reinstantiated addon returned " + reloaded.add(4, 5));',
      "    }",
      '    return reloaded[Symbol.for("napi.rs.wasi.dispose")]();',
      "  })",
      '  .then(() => process.stdout.write("disposed"));',
    ].join("\n");
    const loaded = run(process.execPath, ["-e", load], { cwd: project, timeout: 120_000 });
    assert.equal(loaded.stdout, "disposed", `${flavor.suffix}: ${loaded.stderr}`);
  }

  // The deferred (workerd-safe) loader is generated for the threadless flavor
  // and must instantiate a precompiled module, dispose it, and recreate it.
  const deferred = [
    // `-e` with --input-type=module: no require() next to top-level await.
    'import fs from "node:fs";',
    "const deferred = await import(" +
      JSON.stringify(pathToFileURL(path.join(project, "packed_addon.wasip1-deferred.js")).href) +
      ");",
    "const bytes = fs.readFileSync(" +
      JSON.stringify(path.join(project, "zig-out", "node", "packed_addon.wasm32-wasip1.wasm")) +
      ");",
    "const module = await WebAssembly.compile(bytes);",
    "const instance = await deferred.createInstance(module);",
    "if (instance.exports.add(1, 2) !== 3) {",
    '  throw new Error("deferred add returned " + instance.exports.add(1, 2));',
    "}",
    "await instance.dispose();",
    "const singleton = await deferred.instantiate(module);",
    "if (singleton.add(6, 7) !== 13) {",
    '  throw new Error("deferred singleton returned " + singleton.add(6, 7));',
    "}",
    "await deferred.dispose();",
    'process.stdout.write("deferred-ok");',
  ].join("\n");
  const deferredResult = run(process.execPath, ["--input-type=module", "-e", deferred], {
    cwd: project,
    timeout: 120_000,
  });
  assert.equal(deferredResult.stdout, "deferred-ok", deferredResult.stderr);
});
