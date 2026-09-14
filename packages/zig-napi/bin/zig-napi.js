#!/usr/bin/env node

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { NapiCli } = require("@napi-rs/cli");
const { Command } = require("commander");
const {
  WasiConfigError,
  WASI_WORKER_TEMPLATE,
  collectWasiFlavors,
  createWasiBindingTypeDef,
  createWasiBrowserBinding,
  createWasiBrowserEntry,
  createWasiBrowserWorkerBinding,
  createWasiDeferredBrowserBinding,
  createWasiDeferredBrowserBindingTypeDef,
  createWasiNodeBinding,
  getWasiFlavor,
  isWasiTargetName,
  isWasiThreadsTargetName,
  managedWasiFilesByFlavor,
  managedWasiFileNames,
  normalizeWasiTargetName,
  resolveWasmConfig,
  wasiMemoryBuildArgs,
} = require("./wasi-templates.cjs");

const packageDir = path.resolve(__dirname, "..");
const workspaceRoot = path.resolve(packageDir, "..", "..");
const templateDir = path.join(packageDir, "templates", "node-addon");
const napiCli = new NapiCli();

const availableTargets = [
  "aarch64-apple-darwin",
  "aarch64-linux-android",
  "aarch64-unknown-linux-gnu",
  "aarch64-unknown-linux-musl",
  "aarch64-unknown-linux-ohos",
  "aarch64-pc-windows-msvc",
  "x86_64-apple-darwin",
  "x86_64-pc-windows-msvc",
  "x86_64-pc-windows-gnu",
  "x86_64-unknown-linux-gnu",
  "x86_64-unknown-linux-musl",
  "x86_64-unknown-linux-ohos",
  "x86_64-unknown-freebsd",
  "i686-pc-windows-msvc",
  "armv7-unknown-linux-gnueabihf",
  "armv7-unknown-linux-musleabihf",
  "armv7-linux-androideabi",
  "universal-apple-darwin",
  "loongarch64-unknown-linux-gnu",
  "riscv64gc-unknown-linux-gnu",
  "powerpc64le-unknown-linux-gnu",
  "s390x-unknown-linux-gnu",
  "wasm32-wasip1",
  "wasm32-wasip1-threads",
];

const defaultTargets = [
  "x86_64-apple-darwin",
  "aarch64-apple-darwin",
  "x86_64-pc-windows-msvc",
  "x86_64-unknown-linux-gnu",
];

function fail(message) {
  console.error(`zig-napi: ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    stdio: "inherit",
    shell: false,
  });
  if (result.error) fail(result.error.message);
  if (result.status !== 0) {
    // A linker failure caused by an explicitly configured memory shape is worth
    // a hint: wasm-ld reports the number it could not satisfy, not where the
    // number came from.
    if (options.failureHint) {
      console.error(`zig-napi: ${options.failureHint}`);
    }
    process.exit(result.status || 1);
  }
}

function normalizePathForZig(value) {
  return value.split(path.sep).join("/");
}

function sanitizePackageName(input) {
  return input
    .replace(/[^a-zA-Z0-9@/_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
}

function packageLeafName(input) {
  return input.startsWith("@") ? input.split("/").pop() : input;
}

function sanitizeZigName(input) {
  const value = packageLeafName(sanitizePackageName(input)).replace(/-/g, "_");
  return /^[a-zA-Z_]/.test(value) ? value : `addon_${value}`;
}

function collectTargets(value, previous) {
  return previous.concat(
    value
      .split(",")
      .map((target) => target.trim())
      .filter(Boolean),
  );
}

function resolveNewTargets(flags) {
  const targets = flags.targets.map(normalizeTargetName);

  if (!targets.length) {
    fail("at least one target must be enabled");
  }

  validateTargets(targets);

  return targets;
}

function resolveNonInteractiveTargets(flags) {
  const targets = flags.enableAllTargets
    ? availableTargets
    : flags.targets.length
      ? flags.targets
      : flags.enableDefaultTargets
        ? defaultTargets
        : [];

  return resolveNewTargets({ ...flags, targets });
}

function validateTargets(targets) {
  if (!targets.length) {
    fail("at least one target must be enabled");
  }

  const seen = new Set();
  for (const target of targets) {
    if (!availableTargets.includes(target)) {
      fail(`unknown target: ${target}`);
    }
    if (seen.has(target)) {
      fail(`duplicate target: ${target}`);
    }
    seen.add(target);
  }
}

function normalizeTargetName(target) {
  return normalizeWasiTargetName(target);
}

function formatJsonStringArrayItems(values, indent) {
  return values.map((value) => `${indent}${JSON.stringify(value)}`).join(",\n");
}

function isInteractive(flags) {
  return flags.interactive && process.stdin.isTTY && process.stdout.isTTY;
}

function validatePackageName(value) {
  if (!sanitizePackageName(value)) {
    return "Package name must contain at least one valid package name character";
  }
  return true;
}

function validateAddonName(value) {
  if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(value)) {
    return true;
  }
  return "Addon name must be a valid Zig identifier";
}

function normalizePackageNameOrFail(value) {
  const packageName = sanitizePackageName(value);
  if (!packageName) {
    fail("package name must contain at least one valid package name character");
  }
  return packageName;
}

function validateAddonNameOrFail(value) {
  const result = validateAddonName(value);
  if (result !== true) {
    fail(result);
  }
  return value;
}

async function promptNewOptions(projectDir, flags) {
  if (!isInteractive(flags)) {
    if (!projectDir) {
      fail("project directory is required; pass <dir> or run in an interactive terminal");
    }
    const packageName = normalizePackageNameOrFail(
      flags.name || sanitizePackageName(path.basename(projectDir)),
    );
    return {
      projectDir,
      packageName,
      addonName: validateAddonNameOrFail(flags.addon || sanitizeZigName(packageName)),
      targets: resolveNonInteractiveTargets(flags),
    };
  }

  const { checkbox, input } = await import("@inquirer/prompts");
  const targetPath =
    projectDir ||
    (await input({
      message: "Target path to create the project, relative to cwd.",
      validate: (value) => Boolean(value.trim()) || "Target path is required",
    }));
  const defaultPackageName = sanitizePackageName(path.basename(targetPath));
  const packageName =
    flags.name ||
    (await input({
      message: "Package name (the name field in your package.json file)",
      default: defaultPackageName,
      validate: validatePackageName,
    }));
  const addonName =
    flags.addon ||
    (await input({
      message: "Native addon binary name",
      default: sanitizeZigName(packageName),
      validate: validateAddonName,
    }));

  const targets = flags.enableAllTargets
    ? availableTargets
    : flags.targets.length
      ? flags.targets
      : await checkbox({
          loop: false,
          message: "Choose target(s) your addon will be compiled to",
          choices: availableTargets.map((target) => ({
            name: target,
            value: target,
            checked: flags.enableDefaultTargets && defaultTargets.includes(target),
          })),
        });

  return {
    projectDir: targetPath,
    packageName: normalizePackageNameOrFail(packageName),
    addonName: validateAddonNameOrFail(addonName),
    targets: resolveNewTargets({ ...flags, targets }),
  };
}

function copyTemplate(from, to, replacements) {
  const stat = fs.statSync(from);
  if (stat.isDirectory()) {
    fs.mkdirSync(to, { recursive: true });
    for (const entry of fs.readdirSync(from)) {
      copyTemplate(path.join(from, entry), path.join(to, entry), replacements);
    }
    return;
  }

  let outputPath = to;
  for (const [key, value] of Object.entries(replacements)) {
    outputPath = outputPath.replaceAll(key, value);
  }

  let text = fs.readFileSync(from, "utf8");
  for (const [key, value] of Object.entries(replacements)) {
    text = text.replaceAll(key, value);
  }
  fs.writeFileSync(outputPath, text);
}

function repairZigFingerprint(projectDir) {
  const zonPath = path.join(projectDir, "build.zig.zon");
  const result = childProcess.spawnSync("zig", ["build"], {
    cwd: projectDir,
    encoding: "utf8",
    stdio: "pipe",
    shell: false,
  });
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const match = output.match(/use this value:\s*(0x[0-9a-fA-F]+)/);
  if (!match) {
    if (result.error) {
      console.warn(
        `zig-napi: unable to calculate build.zig.zon fingerprint: ${result.error.message}`,
      );
    }
    return;
  }
  const zon = fs.readFileSync(zonPath, "utf8");
  fs.writeFileSync(
    zonPath,
    zon.replace(/\.fingerprint = 0x[0-9a-fA-F]+,/, `.fingerprint = ${match[1]},`),
  );
}

function napiOptions(flags) {
  return {
    cwd: path.resolve(process.cwd(), flags.cwd || "."),
    configPath: flags.configPath,
    packageJsonPath: flags.packageJsonPath,
    npmDir: flags.npmDir,
    outputDir: flags.outputDir,
    buildOutputDir: flags.buildOutputDir,
    tagStyle: flags.tagStyle,
    ghRelease: flags.ghRelease,
    ghReleaseName: flags.ghReleaseName,
    ghReleaseId: flags.ghReleaseId,
    skipOptionalPublish: flags.skipOptionalPublish,
    dryRun: flags.dryRun,
  };
}

function cleanOptions(options) {
  return Object.fromEntries(Object.entries(options).filter(([, value]) => value !== undefined));
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function readDtsExportIdents(cwd) {
  const dtsPath = path.join(cwd, "index.d.ts");
  if (!fs.existsSync(dtsPath)) return [];

  const dts = fs.readFileSync(dtsPath, "utf8");
  const idents = new Set();
  const exportDeclaration =
    /^export\s+(?:declare\s+)?(?:function|const|let|var|class|enum)\s+([A-Za-z_$][\w$]*)/gm;
  let match = exportDeclaration.exec(dts);
  while (match) {
    idents.add(match[1]);
    match = exportDeclaration.exec(dts);
  }
  return [...idents];
}

/**
 * Package `files` globs for the enabled flavors. The globs are added or removed
 * by the CLI so the scaffold publishes exactly the loaders it generated,
 * whichever flavors the project configures.
 */
const WASI_PACKAGE_FILE_GLOBS = [
  "*.wasm",
  "*.cjs",
  "*.wasi.cjs",
  "*.d.cts",
  "*.wasi-browser.js",
  "*.wasip1-browser.js",
  "browser.js",
  "wasi-worker.mjs",
  "wasi-worker-browser.mjs",
  "*-deferred.js",
  "*-deferred.d.ts",
];

function updateTemplatePackageForTargets(projectDir, targets) {
  const flavors = collectWasiFlavors(targets);
  const packageJsonPath = path.join(projectDir, "package.json");
  const packageJson = readJson(packageJsonPath);
  const files = Array.isArray(packageJson.files) ? packageJson.files : [];

  if (flavors.length === 0) {
    for (const fileName of managedWasiFileNames(readAddonName(packageJson))) {
      fs.rmSync(path.join(projectDir, fileName), { force: true });
    }
    if (packageJson.browser === "browser.js" || packageJson.browser === "./browser.js") {
      delete packageJson.browser;
    }
    packageJson.files = files.filter(
      (file) => file !== "./browser.js" && !WASI_PACKAGE_FILE_GLOBS.includes(file),
    );
    writeJson(packageJsonPath, packageJson);
    return;
  }

  // Keep only the globs of the flavors that are enabled, so a native project
  // never advertises loader files it does not ship.
  const wanted = new Set(
    flavors.flatMap((flavor) =>
      flavor.threads
        ? [
            `*.${flavor.loaderSuffix}.cjs`,
            `*.${flavor.loaderSuffix}-browser.js`,
            "wasi-worker.mjs",
            "wasi-worker-browser.mjs",
          ]
        : [
            `*.${flavor.loaderSuffix}.cjs`,
            `*.${flavor.loaderSuffix}-browser.js`,
            "*-deferred.js",
            "*-deferred.d.ts",
          ],
    ),
  );
  const retained = files.filter(
    (file) => !WASI_PACKAGE_FILE_GLOBS.includes(file) && file !== "./browser.js",
  );
  retained.push("browser.js", "*.wasm", "*.d.cts", ...wanted);
  packageJson.files = [...new Set(retained)];
  writeJson(packageJsonPath, packageJson);
}

function readAddonName(packageJson) {
  const binaryName = packageJson?.napi?.binaryName;
  if (typeof binaryName === "string" && binaryName) {
    return binaryName;
  }
  const binaryNames = packageJson?.napi?.binaryNames;
  if (Array.isArray(binaryNames) && typeof binaryNames[0] === "string") {
    return binaryNames[0];
  }
  return undefined;
}

function resolveZigNapiPath(targetDir, value) {
  const bundled = path.join(packageDir, "zig");
  const source = value
    ? path.resolve(process.cwd(), value)
    : fs.existsSync(path.join(bundled, "build.zig"))
      ? bundled
      : workspaceRoot;
  if (
    !fs.existsSync(path.join(source, "build.zig")) ||
    !fs.existsSync(path.join(source, "src", "napi.zig"))
  ) {
    fail(
      "Zig library sources are missing; reinstall @ohos-rs/zig-cli or pass --zig-napi <source-directory>",
    );
  }
  return path.relative(fs.realpathSync(targetDir), fs.realpathSync(source)) || ".";
}

function readZigNapiConfig(cwd, flags) {
  const packageJsonPath = path.resolve(cwd, flags.packageJsonPath || "package.json");
  const packageJson = readJson(packageJsonPath);
  const configPath = flags.configPath ? path.resolve(cwd, flags.configPath) : null;
  const config = configPath ? readJson(configPath) : packageJson.napi || {};
  return {
    binaryName: config.binaryName,
    binaryNames: Array.isArray(config.binaryNames) ? config.binaryNames : [],
    packageName: config.packageName || packageJson.name,
    targets: Array.isArray(config.targets) ? config.targets : [],
    wasm: config.wasm || {},
  };
}

function readBinaryNames(config) {
  const binaryNames = [];
  if (typeof config.binaryName === "string" && config.binaryName) {
    binaryNames.push(config.binaryName);
  }
  for (const binaryName of config.binaryNames) {
    if (typeof binaryName === "string" && binaryName) {
      binaryNames.push(binaryName);
    }
  }
  return [...new Set(binaryNames)];
}

function appendWasiThreadsBuildFlags(args, target, passthrough) {
  if (!isWasiThreadsTargetName(target)) return;

  const hasCpuOption =
    passthrough.some((arg) => arg === "-Dcpu" || arg.startsWith("-Dcpu=")) ||
    args.some((arg) => arg === "-Dcpu" || arg.startsWith("-Dcpu="));
  if (!hasCpuOption) {
    args.push("-Dcpu=baseline+atomics+bulk_memory+mutable_globals");
  }
}

/**
 * Flavors a run must generate loaders for: the flavor of an explicit
 * `--target`, otherwise every WASI flavor the project configures (threaded
 * first). A project may configure both flavors; each one gets its own loader,
 * worker/deferred scripts and `.wasm` artifact name.
 */
function resolveConfiguredFlavors(config, flags) {
  const explicit = getWasiFlavor(flags?.target);
  if (explicit) {
    return [explicit];
  }
  return collectWasiFlavors(config.targets);
}

/**
 * Rejects misspelled WASI triples instead of silently treating them as native
 * targets, which would build and then fail at runtime.
 */
function validateConfiguredTargets(targets) {
  for (const target of targets) {
    if (typeof target !== "string" || isWasiTargetName(target)) {
      continue;
    }
    if (/^wasm32-(?:wasip|wasi(?:-|$))/.test(target)) {
      fail(
        `unsupported WASI target ${target}; supported targets are wasm32-wasip1, wasm32-wasip1-threads, wasm32-wasi and wasm32-wasi-preview1-threads`,
      );
    }
  }
}

function wasiNodeBindingModule(config, binaryName, flavor, wasm) {
  const wasmFileName = `${binaryName}.${flavor.platformArchABI}`;
  return (
    createWasiNodeBinding({
      wasmFileName,
      packageWasmFileName: wasmFileName,
      packageName: config.packageName,
      platformArchABI: flavor.platformArchABI,
      threads: flavor.threads,
      initialMemory: wasm.initialMemory,
      maximumMemory: wasm.maximumMemory,
    }) + `module.exports = __napiModule.exports\n`
  );
}

function wasiBrowserBindingModule(config, binaryName, flavor, wasm) {
  const wasmFileName = `${binaryName}.${flavor.platformArchABI}`;
  return createWasiBrowserBinding({
    wasmFileName,
    threads: flavor.threads,
    initialMemory: wasm.initialMemory,
    maximumMemory: wasm.maximumMemory,
    fs: wasm.browser.fs,
    asyncInit: wasm.browser.asyncInit,
    buffer: wasm.browser.buffer,
    errorEvent: wasm.browser.errorEvent,
  });
}

function wasiDeferredBindingModule(binaryName, flavor, wasm) {
  return createWasiDeferredBrowserBinding({
    wasmFileName: `${binaryName}.${flavor.platformArchABI}`,
    initialMemory: wasm.initialMemory,
    maximumMemory: wasm.maximumMemory,
    buffer: wasm.browser.buffer,
  });
}

function appendWasiExports(source, exportIdents, kind) {
  const namedExports = exportIdents
    .map((ident) =>
      kind === "cjs"
        ? `module.exports.${ident} = __napiModule.exports.${ident}`
        : `export const ${ident} = __napiModule.exports.${ident}`,
    )
    .join("\n");
  const defaultExport = kind === "esm" ? `export default __napiModule.exports` : "";
  const exportsCode = [defaultExport, namedExports].filter(Boolean).join("\n");
  return exportsCode ? `${source}\n${exportsCode}\n` : source;
}

/**
 * Writes every generated file of one flavor. Only files this run wrote are
 * kept: `removeStaleWasiArtifacts` deletes the loaders of flavors the project
 * no longer configures.
 */
function writeWasiFlavorArtifacts(options) {
  const { outputDir, config, binaryName, flavor, wasm, exportIdents, written } = options;
  const suffix = flavor.loaderSuffix;
  const write = (fileName, content) => {
    fs.writeFileSync(path.join(outputDir, fileName), content);
    written.add(fileName);
  };

  write(
    `${binaryName}.${suffix}.cjs`,
    appendWasiExports(wasiNodeBindingModule(config, binaryName, flavor, wasm), exportIdents, "cjs"),
  );
  write(`${binaryName}.${suffix}.d.cts`, createWasiBindingTypeDef(`./${binaryName}.${suffix}.cjs`));
  write(
    `${binaryName}.${suffix}-browser.js`,
    appendWasiExports(
      wasiBrowserBindingModule(config, binaryName, flavor, wasm),
      exportIdents,
      "esm",
    ),
  );

  if (flavor.threads) {
    write("wasi-worker.mjs", WASI_WORKER_TEMPLATE);
    write(
      "wasi-worker-browser.mjs",
      createWasiBrowserWorkerBinding(wasm.browser.fs, wasm.browser.errorEvent),
    );
    return;
  }

  write(`${binaryName}.${suffix}-deferred.js`, wasiDeferredBindingModule(binaryName, flavor, wasm));
  write(
    `${binaryName}.${suffix}-deferred.d.ts`,
    createWasiDeferredBrowserBindingTypeDef(`./${binaryName}.${suffix}.cjs`),
  );
}

/**
 * Deletes loader files of flavors that are neither generated by this run nor
 * configured for the project, so building one flavor does not remove the other
 * configured flavor's artifacts. Only names the CLI owns for one of the
 * project's binaries can be removed, so a hand-written file next to the
 * generated ones is never touched.
 */
function removeStaleWasiArtifacts(outputDir, binaryNames, written, retainedFlavors) {
  const retained = new Set(retainedFlavors.map((flavor) => flavor.platformArchABI));
  for (const binaryName of binaryNames) {
    for (const { flavor, fileName } of managedWasiFilesByFlavor(binaryName)) {
      if (!written.has(fileName) && !retained.has(flavor.platformArchABI)) {
        fs.rmSync(path.join(outputDir, fileName), { force: true });
      }
    }
  }
}

/**
 * The browser entry re-exports the flavor's optional package. A threadless
 * flavor is preferred when both are configured: it runs in a browser without
 * cross-origin isolation, which the threaded flavor requires.
 */
function resolveBrowserEntryFlavor(flavors) {
  return flavors.find((flavor) => !flavor.threads) ?? flavors[0];
}

async function generateWasiBindings(cwd, flags) {
  const config = readZigNapiConfig(cwd, flags);
  return generateWasiBindingsWithConfig(cwd, flags, config, readDtsExportIdents(cwd));
}

async function generateWasiBindingsWithConfig(cwd, flags, config, exportIdents) {
  validateConfiguredTargets([...(flags.target ? [flags.target] : []), ...config.targets]);
  const flavors = resolveConfiguredFlavors(config, flags);
  if (flavors.length === 0) return;

  let wasm;
  try {
    wasm = resolveWasmConfig(config);
  } catch (error) {
    if (error instanceof WasiConfigError) fail(error.message);
    throw error;
  }

  const binaryNames = readBinaryNames(config);
  if (binaryNames.length === 0) fail("missing napi.binaryName; required to generate wasm bindings");
  if (!config.packageName) fail("missing package name; required to generate wasm bindings");

  const outputDir = path.resolve(cwd, flags.buildOutputDir || ".");
  fs.mkdirSync(outputDir, { recursive: true });

  const written = new Set();
  for (const binaryName of binaryNames) {
    for (const flavor of flavors) {
      writeWasiFlavorArtifacts({
        outputDir,
        config,
        binaryName,
        flavor,
        wasm,
        exportIdents,
        written,
      });
    }
  }
  // Configured flavors count too: a single-flavor build must not repoint the
  // entry at a flavor the project does not actually ship.
  const entryFlavor = resolveBrowserEntryFlavor([
    ...flavors,
    ...collectWasiFlavors(config.targets),
  ]);
  fs.writeFileSync(
    path.join(outputDir, "browser.js"),
    createWasiBrowserEntry(config.packageName, entryFlavor.platformArchABI, exportIdents),
  );
  written.add("browser.js");
  const retainedFlavors = [...flavors, ...collectWasiFlavors(config.targets)];
  removeStaleWasiArtifacts(outputDir, binaryNames, written, retainedFlavors);
}

/**
 * The linked module imports the memory the loader allocates, so the limits have
 * to match `napi.wasm` exactly. The options are declared once by the zig-napi
 * build helper (`src/build/napi-build.zig`), so they are always accepted; the
 * CLI never probes the build script for them.
 */
function appendWasiMemoryBuildFlags(args, config, flavors) {
  if (flavors.length === 0) return;
  let buildArgs;
  try {
    buildArgs = wasiMemoryBuildArgs(config);
  } catch (error) {
    if (error instanceof WasiConfigError) fail(error.message);
    throw error;
  }
  args.push(...buildArgs);
}

/**
 * The linker owns the lower bound of the imported memory (linked data plus the
 * stack), so a configured `initialMemory` that is too small for the image fails
 * inside wasm-ld. Turn that into a message that names the configuration the
 * number came from. The stack is whatever the build uses - 16 MiB by default,
 * but a project may pass `-Dwasi-stack-size`, so the hint names both.
 */
function wasiMemoryFailureHint(config, flavors) {
  if (flavors.length === 0) return undefined;
  const wasm = config?.wasm ?? {};
  if (wasm.initialMemory === undefined && wasm.maximumMemory === undefined) {
    return undefined;
  }
  return `the link failed while napi.wasm.initialMemory=${wasm.initialMemory ?? "default"}/${wasm.maximumMemory ?? "default"} (pages) was passed as -Dwasi-initial-memory-pages/-Dwasi-max-memory-pages; the initial memory must cover the linked image, which is the linked data plus the stack (16 MiB unless the build passes -Dwasi-stack-size), so raise napi.wasm.initialMemory or lower -Dwasi-stack-size if wasm-ld reports the initial memory as too small`;
}

const EMNAPI_PACKAGES = ["emnapi", "@emnapi/core", "@emnapi/runtime"];

/** Directory of an installed package resolved from the project, if any. */
function resolveInstalledPackageDir(cwd, name) {
  const resolveOptions = { paths: [cwd] };
  try {
    return path.dirname(require.resolve(`${name}/package.json`, resolveOptions));
  } catch {}
  try {
    let directory = path.dirname(require.resolve(name, resolveOptions));
    for (;;) {
      const manifestPath = path.join(directory, "package.json");
      if (fs.existsSync(manifestPath)) {
        return directory;
      }
      const parent = path.dirname(directory);
      if (parent === directory) {
        return undefined;
      }
      directory = parent;
    }
  } catch {
    return undefined;
  }
}

function readPackageVersion(directory) {
  try {
    const version = JSON.parse(
      fs.readFileSync(path.join(directory, "package.json"), "utf8"),
    ).version;
    return typeof version === "string" ? version : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The archive the linker uses, the JS plugins and the emnapi runtime must come
 * from one release: emnapi v2 archives leave async work and thread-safe
 * functions to the `@emnapi/core` plugins, and a mixed install would link an
 * archive whose ABI the loaded runtime does not implement. Package resolution
 * failures are left to the build helper, which reports the archive it needs;
 * this check only rejects a resolvable-but-wrong install.
 */
function resolveEmnapiRuntime(cwd) {
  const versions = new Map();
  for (const name of EMNAPI_PACKAGES) {
    const directory = resolveInstalledPackageDir(cwd, name);
    if (directory) {
      versions.set(name, { directory, version: readPackageVersion(directory) });
    }
  }
  if (versions.size === 0) {
    return undefined;
  }
  const missing = EMNAPI_PACKAGES.filter((name) => !versions.has(name));
  if (missing.length > 0) {
    fail(
      `WASI builds need ${EMNAPI_PACKAGES.join(", ")} installed in the project; missing ${missing.join(", ")}`,
    );
  }
  const distinct = new Set([...versions.values()].map((entry) => entry.version));
  if (distinct.size > 1) {
    fail(
      `emnapi version mismatch: ${EMNAPI_PACKAGES.map(
        (name) => `${name}@${versions.get(name).version}`,
      ).join(", ")}. Install one emnapi release across emnapi, @emnapi/core and @emnapi/runtime`,
    );
  }
  const version = [...distinct][0];
  if (typeof version === "string" && version.startsWith("1.")) {
    fail(
      `emnapi@${version} cannot build WASI addons; zig-napi links the emnapi v2 archives (2.0.0-alpha.5 or newer)`,
    );
  }
  return { version, libDir: path.join(versions.get("emnapi").directory, "lib") };
}

/**
 * Points the build at the project's own emnapi archives instead of letting the
 * helper walk every ancestor directory, so a hoisted install and a nested one
 * cannot resolve to different releases. The value travels as `EMNAPI_LINK_DIR`
 * (the environment setting the build helper already reads) rather than as a
 * `-D` option, so a project pinned to an older zig-napi build script keeps
 * building instead of failing on an undeclared option.
 */
function resolveWasiEmnapiEnv(cwd) {
  const runtime = resolveEmnapiRuntime(cwd);
  if (!runtime) {
    console.warn(
      "zig-napi: cannot resolve emnapi from this project; the WASI build relies on the build helper to find its archive",
    );
    return undefined;
  }
  if (fs.existsSync(runtime.libDir)) {
    return { EMNAPI_LINK_DIR: runtime.libDir };
  }
  return undefined;
}

async function commandNew(projectDir, flags) {
  const options = await promptNewOptions(projectDir, flags);
  const targetDir = path.resolve(process.cwd(), options.projectDir);
  if (fs.existsSync(targetDir) && fs.readdirSync(targetDir).length && !flags.force) {
    fail(`${targetDir} is not empty; pass --force to write into it`);
  }

  const packageName = options.packageName;
  const addonName = options.addonName;
  fs.mkdirSync(targetDir, { recursive: true });
  const zigNapiZigPath = resolveZigNapiPath(targetDir, flags.zigNapi);

  copyTemplate(templateDir, targetDir, {
    __PACKAGE_NAME__: packageName,
    __ADDON_NAME__: addonName,
    __ZIG_PACKAGE_NAME__: sanitizeZigName(packageName),
    __ZIG_NAPI_ZIG_PATH__: JSON.stringify(normalizePathForZig(zigNapiZigPath)).slice(1, -1),
    '      "__NAPI_TARGETS__"': formatJsonStringArrayItems(options.targets, "      "),
    __FINGERPRINT__: "0x0",
    __CLI_VERSION__: readJson(path.join(packageDir, "package.json")).version,
  });
  // Loaders are generated from the same code path a build uses, so a scaffold
  // and a built project cannot drift apart.
  await generateWasiBindings(targetDir, { target: undefined, buildOutputDir: "." });
  updateTemplatePackageForTargets(targetDir, options.targets);
  repairZigFingerprint(targetDir);

  console.log(`Created ${packageName} in ${targetDir}`);
}

async function commandBuild(flags, passthrough = []) {
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  const config = readZigNapiConfig(cwd, flags);
  // Validate before spending a build on a configuration the generated loaders
  // could not use.
  const flavors = resolveConfiguredFlavors(config, flags);
  try {
    resolveWasmConfig(config);
  } catch (error) {
    if (error instanceof WasiConfigError) fail(error.message);
    throw error;
  }
  const args = ["build"];
  if (flags.release) args.push("-Doptimize=ReleaseFast");
  if (flags.target) {
    // Both WASI flavors build Zig's wasm32-wasi target; only the threaded one
    // enables atomics/shared memory.
    args.push(`-Dtarget=${isWasiTargetName(flags.target) ? "wasm32-wasi" : flags.target}`);
  }
  appendWasiThreadsBuildFlags(args, flags.target, passthrough);
  appendWasiMemoryBuildFlags(args, config, flavors);
  args.push(...passthrough);
  const emnapiEnv = flavors.length > 0 ? resolveWasiEmnapiEnv(cwd) : undefined;
  run("zig", args, {
    cwd,
    env: emnapiEnv ? { ...process.env, ...emnapiEnv } : process.env,
    failureHint: wasiMemoryFailureHint(config, flavors),
  });
  await generateWasiBindingsWithConfig(cwd, flags, config, readDtsExportIdents(cwd));
}

function commandDts(flags, passthrough = []) {
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  run("zig", ["build", ...passthrough], { cwd });
}

async function commandCreateNpmDirs(flags) {
  await napiCli.createNpmDirs(
    cleanOptions({
      cwd: path.resolve(process.cwd(), flags.cwd || "."),
      configPath: flags.configPath,
      packageJsonPath: flags.packageJsonPath,
      npmDir: flags.npmDir,
      dryRun: flags.dryRun,
    }),
  );
}

async function commandArtifacts(flags) {
  await generateWasiBindings(path.resolve(process.cwd(), flags.cwd || "."), flags);
  await napiCli.artifacts(cleanOptions(napiOptions(flags)));
}

async function commandPrePublish(flags) {
  await napiCli.prePublish(cleanOptions(napiOptions(flags)));
}

async function commandPackage(flags) {
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  await napiCli.createNpmDirs(
    cleanOptions({
      cwd,
      configPath: flags.configPath,
      packageJsonPath: flags.packageJsonPath,
      npmDir: flags.npmDir,
      dryRun: flags.dryRun,
    }),
  );
  await commandBuild({ ...flags, cwd, release: flags.release, target: flags.target });
  await napiCli.artifacts(
    cleanOptions({
      cwd,
      configPath: flags.configPath,
      packageJsonPath: flags.packageJsonPath,
      outputDir: flags.outputDir || "zig-out/node",
      npmDir: flags.npmDir,
      buildOutputDir: flags.buildOutputDir,
    }),
  );
}

function addCwdOption(command) {
  return command.option("--cwd <dir>", "project directory", ".");
}

function addBuildOptions(command) {
  return addBuildFlags(addCwdOption(command));
}

function addBuildFlags(command) {
  return command
    .option("--release", "build with ReleaseFast optimization")
    .option("--target <zig-target>", "Zig target triple");
}

function addNapiPathOptions(command) {
  return addCwdOption(command)
    .option("--config-path <file>", "path to napi config")
    .option("--package-json-path <file>", "path to package.json")
    .option("--npm-dir <dir>", "npm package directory");
}

function addNapiOptions(command) {
  return addNapiPathOptions(command)
    .option("--output-dir <dir>", "Zig build output directory")
    .option("--build-output-dir <dir>", "build output directory")
    .option("--tag-style <style>", "npm tag style")
    .option("--gh-release", "enable GitHub release handling")
    .option("--no-gh-release", "disable GitHub release handling")
    .option("--gh-release-name <name>", "GitHub release name")
    .option("--gh-release-id <id>", "GitHub release id")
    .option("--skip-optional-publish", "skip optional dependency package publishing")
    .option("--dry-run", "print planned changes without writing");
}

function createProgram() {
  const program = new Command();

  program
    .name("zig-napi")
    .description("CLI tools for building Node.js addons with zig-napi")
    .showHelpAfterError()
    .showSuggestionAfterError();

  program
    .command("new")
    .description("create a Zig Node-API addon project")
    .argument("[dir]", "project directory")
    .option("--name <package>", "npm package name")
    .option("--addon <name>", "native addon binary name")
    .option("--zig-napi <path>", "path to zig-napi Zig package, relative to the current directory")
    .option("-i, --interactive", "ask project information interactively", true)
    .option("--no-interactive", "disable interactive prompts")
    .option(
      "-t, --targets <target>",
      "target triple to enable; repeat or comma-separate",
      collectTargets,
      [],
    )
    .option("--enable-default-targets", "enable the default napi-rs targets", true)
    .option("--no-enable-default-targets", "disable the default napi-rs targets")
    .option("--enable-all-targets", "enable all napi-rs targets")
    .option("--force", "write into a non-empty directory")
    .action(commandNew);

  addBuildOptions(
    program
      .command("build")
      .description("run zig build for a Zig addon project")
      .allowUnknownOption(true)
      .argument("[zigBuildArgs...]", "extra arguments forwarded to zig build"),
  ).action((zigBuildArgs, options) => commandBuild(options, zigBuildArgs));

  addCwdOption(
    program
      .command("dts")
      .description("run zig build so template projects emit index.d.ts")
      .allowUnknownOption(true)
      .argument("[zigBuildArgs...]", "extra arguments forwarded to zig build"),
  ).action((zigBuildArgs, options) => commandDts(options, zigBuildArgs));

  addNapiPathOptions(
    program.command("create-npm-dirs").description("call @napi-rs/cli createNpmDirs API"),
  )
    .option("--dry-run", "print planned changes without writing")
    .action(commandCreateNpmDirs);

  addNapiOptions(
    program.command("artifacts").description("call @napi-rs/cli artifacts API"),
  ).action(commandArtifacts);

  addNapiOptions(
    program.command("pre-publish").description("call @napi-rs/cli prePublish API"),
  ).action(commandPrePublish);

  addBuildFlags(
    addNapiPathOptions(
      program.command("package").description("run create-npm-dirs, build, and artifacts"),
    ),
  )
    .option("--output-dir <dir>", "Zig build output directory", "zig-out/node")
    .option("--build-output-dir <dir>", "build output directory")
    .option("--dry-run", "print planned changes without writing")
    .action(commandPackage);

  return program;
}

async function main() {
  const program = createProgram();
  if (process.argv.length <= 2) {
    program.outputHelp();
    return;
  }
  await program.parseAsync(process.argv);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
