#!/usr/bin/env node

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { NapiCli, parseTriple } = require("@napi-rs/cli");
const { Command } = require("commander");

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
  "wasm32-wasi-preview1-threads",
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
    stdio: "inherit",
    shell: process.platform === "win32",
  });
  if (result.error) fail(result.error.message);
  if (result.status !== 0) process.exit(result.status || 1);
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
  return target === "wasm32-wasi-preview1-threads" ? "wasm32-wasip1-threads" : target;
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
    shell: process.platform === "win32",
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

function isWasiTargetName(target) {
  if (!target) return false;
  try {
    const parsed = parseTriple(target);
    return parsed.platformArchABI === "wasm32-wasi";
  } catch {
    return target === "wasm32-wasi" || target.startsWith("wasm32-wasip");
  }
}

function isWasiThreadsTargetName(target) {
  return target === "wasm32-wasi-preview1-threads" || target === "wasm32-wasip1-threads";
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

function createWasiBinding(wasmFileName, packageName, initialMemory = 4000, maximumMemory = 65536) {
  return `/* eslint-disable */
/* auto-generated by zig-napi */

const __nodeFs = require('node:fs')
const __nodePath = require('node:path')
const { WASI: __nodeWASI } = require('node:wasi')
const { Worker } = require('node:worker_threads')

const {
  createOnMessage: __wasmCreateOnMessageForFsProxy,
  getDefaultContext: __emnapiGetDefaultContext,
  instantiateNapiModuleSync: __emnapiInstantiateNapiModuleSync,
} = require('@napi-rs/wasm-runtime')

const __rootDir = __nodePath.parse(process.cwd()).root

const __wasi = new __nodeWASI({
  version: 'preview1',
  env: process.env,
  preopens: {
    [__rootDir]: __rootDir,
  },
})

const __emnapiContext = __emnapiGetDefaultContext()

const __sharedMemory = new WebAssembly.Memory({
  initial: ${initialMemory},
  maximum: ${maximumMemory},
  shared: true,
})

const __wasmCandidates = [
  __nodePath.join(__dirname, '${wasmFileName}.debug.wasm'),
  __nodePath.join(__dirname, '${wasmFileName}.wasm'),
  __nodePath.join(__dirname, 'zig-out', 'node', '${wasmFileName}.debug.wasm'),
  __nodePath.join(__dirname, 'zig-out', 'node', '${wasmFileName}.wasm'),
]

let __wasmFilePath = __wasmCandidates.find((candidate) => __nodeFs.existsSync(candidate))

if (!__wasmFilePath) {
  try {
    __wasmFilePath = require.resolve('${packageName}-wasm32-wasi/${wasmFileName}.wasm')
  } catch {
    throw new Error('Cannot find ${wasmFileName}.wasm file, and ${packageName}-wasm32-wasi package is not installed.')
  }
}

const {
  instance: __napiInstance,
  module: __wasiModule,
  napiModule: __napiModule,
} = __emnapiInstantiateNapiModuleSync(__nodeFs.readFileSync(__wasmFilePath), {
  context: __emnapiContext,
  asyncWorkPoolSize: (function () {
    const threadsSizeFromEnv = Number(process.env.NAPI_RS_ASYNC_WORK_POOL_SIZE ?? process.env.UV_THREADPOOL_SIZE)
    return threadsSizeFromEnv > 0 ? threadsSizeFromEnv : 4
  })(),
  reuseWorker: true,
  wasi: __wasi,
  onCreateWorker() {
    const worker = new Worker(__nodePath.join(__dirname, 'wasi-worker.mjs'), {
      env: process.env,
    })
    worker.onmessage = ({ data }) => {
      __wasmCreateOnMessageForFsProxy(__nodeFs)(data)
    }

    {
      const kPublicPort = Object.getOwnPropertySymbols(worker).find((symbol) =>
        symbol.toString().includes('kPublicPort')
      )
      if (kPublicPort) {
        worker[kPublicPort].ref = () => {}
      }

      const kHandle = Object.getOwnPropertySymbols(worker).find((symbol) =>
        symbol.toString().includes('kHandle')
      )
      if (kHandle) {
        worker[kHandle].ref = () => {}
      }

      worker.unref()
    }
    return worker
  },
  overwriteImports(importObject) {
    importObject.env = {
      ...importObject.env,
      ...importObject.napi,
      ...importObject.emnapi,
      memory: __sharedMemory,
    }
    return importObject
  },
  beforeInit({ instance }) {
    for (const name of Object.keys(instance.exports)) {
      if (name.startsWith('__napi_register__')) {
        instance.exports[name]()
      }
    }
  },
})

module.exports = __napiModule.exports
`;
}

function createWasiBrowserBinding(wasmFileName, initialMemory = 4000, maximumMemory = 65536) {
  return `/* auto-generated by zig-napi */
import {
  getDefaultContext as __emnapiGetDefaultContext,
  instantiateNapiModuleSync as __emnapiInstantiateNapiModuleSync,
  WASI as __WASI,
} from '@napi-rs/wasm-runtime'

const __wasi = new __WASI({
  version: 'preview1',
})

const __wasmUrl = new URL('./${wasmFileName}.wasm', import.meta.url).href
const __emnapiContext = __emnapiGetDefaultContext()

const __sharedMemory = new WebAssembly.Memory({
  initial: ${initialMemory},
  maximum: ${maximumMemory},
  shared: true,
})

const __wasmFile = await fetch(__wasmUrl).then((res) => res.arrayBuffer())

const {
  instance: __napiInstance,
  module: __wasiModule,
  napiModule: __napiModule,
} = __emnapiInstantiateNapiModuleSync(__wasmFile, {
  context: __emnapiContext,
  asyncWorkPoolSize: 4,
  wasi: __wasi,
  onCreateWorker() {
    return new Worker(new URL('./wasi-worker-browser.mjs', import.meta.url), {
      type: 'module',
    })
  },
  overwriteImports(importObject) {
    importObject.env = {
      ...importObject.env,
      ...importObject.napi,
      ...importObject.emnapi,
      memory: __sharedMemory,
    }
    return importObject
  },
  beforeInit({ instance }) {
    for (const name of Object.keys(instance.exports)) {
      if (name.startsWith('__napi_register__')) {
        instance.exports[name]()
      }
    }
  },
})

export default __napiModule.exports
`;
}

const WASI_WORKER_TEMPLATE = `import fs from "node:fs";
import { createRequire } from "node:module";
import { parse } from "node:path";
import { WASI } from "node:wasi";
import { parentPort, Worker } from "node:worker_threads";

const require = createRequire(import.meta.url);

const { instantiateNapiModuleSync, MessageHandler, getDefaultContext } = require("@napi-rs/wasm-runtime");

if (parentPort) {
  parentPort.on("message", (data) => {
    globalThis.onmessage({ data });
  });
}

Object.assign(globalThis, {
  self: globalThis,
  require,
  Worker,
  importScripts(f) {
    ;(0, eval)(fs.readFileSync(f, "utf8") + "//# sourceURL=" + f);
  },
  postMessage(msg) {
    if (parentPort) {
      parentPort.postMessage(msg);
    }
  },
});

const emnapiContext = getDefaultContext();
const __rootDir = parse(process.cwd()).root;

const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    const wasi = new WASI({
      version: "preview1",
      env: process.env,
      preopens: {
        [__rootDir]: __rootDir,
      },
    });

    return instantiateNapiModuleSync(wasmModule, {
      childThread: true,
      wasi,
      context: emnapiContext,
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: wasmMemory,
        };
      },
    });
  },
});

globalThis.onmessage = function (event) {
  handler.handle(event);
};
`;

const WASI_BROWSER_WORKER_TEMPLATE = `import { instantiateNapiModuleSync, MessageHandler, WASI } from '@napi-rs/wasm-runtime'

const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    const wasi = new WASI({})
    return instantiateNapiModuleSync(wasmModule, {
      childThread: true,
      wasi,
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: wasmMemory,
        }
      },
    })
  },
})

globalThis.onmessage = function (event) {
  handler.handle(event)
}
`;

async function generateWasiBindings(cwd, flags) {
  const config = readZigNapiConfig(cwd, flags);
  const shouldGenerate =
    isWasiTargetName(flags.target) || config.targets.some((target) => isWasiTargetName(target));

  if (!shouldGenerate) return;
  const binaryNames = readBinaryNames(config);
  if (binaryNames.length === 0) fail("missing napi.binaryName; required to generate wasm bindings");
  if (!config.packageName) fail("missing package name; required to generate wasm bindings");

  const outputDir = path.resolve(cwd, flags.buildOutputDir || ".");
  fs.mkdirSync(outputDir, { recursive: true });

  const initialMemory = config.wasm.initialMemory || 4000;
  const maximumMemory = config.wasm.maximumMemory || 65536;

  for (const binaryName of binaryNames) {
    const wasmFileName = `${binaryName}.wasm32-wasi`;
    fs.writeFileSync(
      path.join(outputDir, `${binaryName}.wasi.cjs`),
      createWasiBinding(wasmFileName, config.packageName, initialMemory, maximumMemory),
    );
    fs.writeFileSync(
      path.join(outputDir, `${binaryName}.wasi-browser.js`),
      createWasiBrowserBinding(wasmFileName, initialMemory, maximumMemory),
    );
  }
  fs.writeFileSync(path.join(outputDir, "wasi-worker.mjs"), WASI_WORKER_TEMPLATE);
  fs.writeFileSync(path.join(outputDir, "wasi-worker-browser.mjs"), WASI_BROWSER_WORKER_TEMPLATE);
}

async function commandNew(projectDir, flags) {
  const options = await promptNewOptions(projectDir, flags);
  const targetDir = path.resolve(process.cwd(), options.projectDir);
  if (fs.existsSync(targetDir) && fs.readdirSync(targetDir).length && !flags.force) {
    fail(`${targetDir} is not empty; pass --force to write into it`);
  }

  const packageName = options.packageName;
  const addonName = options.addonName;
  const zigNapiZigPath = flags.zigNapi || path.relative(targetDir, workspaceRoot) || ".";

  fs.mkdirSync(targetDir, { recursive: true });
  copyTemplate(templateDir, targetDir, {
    __PACKAGE_NAME__: packageName,
    __ADDON_NAME__: addonName,
    __ZIG_PACKAGE_NAME__: sanitizeZigName(packageName),
    __ZIG_NAPI_ZIG_PATH__: normalizePathForZig(zigNapiZigPath),
    '      "__NAPI_TARGETS__"': formatJsonStringArrayItems(options.targets, "      "),
    __FINGERPRINT__: "0x0",
  });
  repairZigFingerprint(targetDir);

  console.log(`Created ${packageName} in ${targetDir}`);
}

async function commandBuild(flags, passthrough = []) {
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  const args = ["build"];
  if (flags.release) args.push("-Doptimize=ReleaseFast");
  if (flags.target) {
    args.push(`-Dtarget=${isWasiThreadsTargetName(flags.target) ? "wasm32-wasi" : flags.target}`);
  }
  appendWasiThreadsBuildFlags(args, flags.target, passthrough);
  args.push(...passthrough);
  run("zig", args, { cwd });
  await generateWasiBindings(cwd, flags);
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
    .option("--zig-napi <path>", "path to zig-napi Zig package from the new project")
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
