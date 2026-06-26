#!/usr/bin/env node

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { NapiCli, parseTriple } = require("@napi-rs/cli");

const rootDir = path.resolve(__dirname, "..");
const templateDir = path.join(rootDir, "templates", "node-addon");
const napiCli = new NapiCli();

function printHelp() {
  console.log(`zig-napi

Usage:
  zig-napi new <dir> [--name <package>] [--addon <name>] [--zig-napi <path>] [--force]
  zig-napi build [--cwd <dir>] [--release] [--target <zig-target>] [-- <zig-build-args>]
  zig-napi dts [--cwd <dir>] [-- <zig-build-args>]
  zig-napi create-npm-dirs [--cwd <dir>] [--config-path <file>] [--package-json-path <file>] [--npm-dir <dir>] [--dry-run]
  zig-napi artifacts [--cwd <dir>] [--config-path <file>] [--package-json-path <file>] [--output-dir <dir>] [--npm-dir <dir>]
  zig-napi pre-publish [--cwd <dir>] [--config-path <file>] [--package-json-path <file>] [--npm-dir <dir>] [--no-gh-release] [--skip-optional-publish] [--dry-run]
  zig-napi package [--cwd <dir>] [--release] [--target <zig-target>] [--npm-dir <dir>] [--output-dir <dir>]

Commands:
  new              Create a Zig Node-API addon project.
  build            Run zig build for a Zig addon project.
  dts              Run zig build so template projects emit index.d.ts.
  create-npm-dirs  Call @napi-rs/cli createNpmDirs API.
  artifacts        Call @napi-rs/cli artifacts API.
  pre-publish      Call @napi-rs/cli prePublish API.
  package          Run create-npm-dirs, build, and artifacts.
`);
}

function parseArgs(argv) {
  const args = [];
  const flags = {};
  let passthrough = [];

  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (item === "--") {
      passthrough = argv.slice(i + 1);
      break;
    }
    if (!item.startsWith("--")) {
      args.push(item);
      continue;
    }

    const eq = item.indexOf("=");
    if (eq !== -1) {
      flags[item.slice(2, eq)] = item.slice(eq + 1);
      continue;
    }

    const key = item.startsWith("--no-") ? item.slice(5) : item.slice(2);
    if (item.startsWith("--no-")) {
      flags[key] = false;
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) {
      flags[key] = argv[i + 1];
      i += 1;
    } else {
      flags[key] = true;
    }
  }

  return { args, flags, passthrough };
}

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
    configPath: flags["config-path"],
    packageJsonPath: flags["package-json-path"],
    npmDir: flags["npm-dir"],
    outputDir: flags["output-dir"],
    buildOutputDir: flags["build-output-dir"],
    tagStyle: flags["tag-style"],
    ghRelease: flags["gh-release"],
    ghReleaseName: flags["gh-release-name"],
    ghReleaseId: flags["gh-release-id"],
    skipOptionalPublish: flags["skip-optional-publish"],
    dryRun: flags["dry-run"],
  };
}

function cleanOptions(options) {
  return Object.fromEntries(Object.entries(options).filter(([, value]) => value !== undefined));
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function readZigNapiConfig(cwd, flags) {
  const packageJsonPath = path.resolve(cwd, flags["package-json-path"] || "package.json");
  const packageJson = readJson(packageJsonPath);
  const configPath = flags["config-path"] ? path.resolve(cwd, flags["config-path"]) : null;
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

  const outputDir = path.resolve(cwd, flags["build-output-dir"] || ".");
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

function commandNew(argv) {
  const { args, flags } = parseArgs(argv);
  const projectDir = args[0];
  if (!projectDir) fail("missing project directory");

  const targetDir = path.resolve(process.cwd(), projectDir);
  if (fs.existsSync(targetDir) && fs.readdirSync(targetDir).length && !flags.force) {
    fail(`${targetDir} is not empty; pass --force to write into it`);
  }

  const packageName = flags.name || sanitizePackageName(path.basename(targetDir));
  const addonName = flags.addon || sanitizeZigName(packageName);
  const zigNapiPath = flags["zig-napi"] || path.relative(targetDir, rootDir) || ".";

  fs.mkdirSync(targetDir, { recursive: true });
  copyTemplate(templateDir, targetDir, {
    __PACKAGE_NAME__: packageName,
    __ADDON_NAME__: addonName,
    __ZIG_PACKAGE_NAME__: sanitizeZigName(packageName),
    __ZIG_NAPI_PATH__: normalizePathForZig(zigNapiPath),
    __FINGERPRINT__: "0x0",
  });
  repairZigFingerprint(targetDir);

  console.log(`Created ${packageName} in ${targetDir}`);
}

async function commandBuild(argv) {
  const { flags, passthrough } = parseArgs(argv);
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  const args = ["build"];
  if (flags.release) args.push("-Doptimize=ReleaseFast");
  if (flags.target) args.push(`-Dtarget=${isWasiThreadsTargetName(flags.target) ? "wasm32-wasi" : flags.target}`);
  appendWasiThreadsBuildFlags(args, flags.target, passthrough);
  args.push(...passthrough);
  run("zig", args, { cwd });
  await generateWasiBindings(cwd, flags);
}

function commandDts(argv) {
  const { flags, passthrough } = parseArgs(argv);
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  run("zig", ["build", ...passthrough], { cwd });
}

async function commandCreateNpmDirs(argv) {
  const { flags } = parseArgs(argv);
  await napiCli.createNpmDirs(
    cleanOptions({
      cwd: path.resolve(process.cwd(), flags.cwd || "."),
      configPath: flags["config-path"],
      packageJsonPath: flags["package-json-path"],
      npmDir: flags["npm-dir"],
      dryRun: flags["dry-run"],
    }),
  );
}

async function commandArtifacts(argv) {
  const { flags } = parseArgs(argv);
  await generateWasiBindings(path.resolve(process.cwd(), flags.cwd || "."), flags);
  await napiCli.artifacts(cleanOptions(napiOptions(flags)));
}

async function commandPrePublish(argv) {
  const { flags } = parseArgs(argv);
  await napiCli.prePublish(cleanOptions(napiOptions(flags)));
}

async function commandPackage(argv) {
  const { flags } = parseArgs(argv);
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  await napiCli.createNpmDirs(
    cleanOptions({
      cwd,
      configPath: flags["config-path"],
      packageJsonPath: flags["package-json-path"],
      npmDir: flags["npm-dir"],
      dryRun: flags["dry-run"],
    }),
  );
  await commandBuild([
    "--cwd",
    cwd,
    ...(flags.release ? ["--release"] : []),
    ...(flags.target ? ["--target", flags.target] : []),
  ]);
  await generateWasiBindings(cwd, flags);
  await napiCli.artifacts(
    cleanOptions({
      cwd,
      configPath: flags["config-path"],
      packageJsonPath: flags["package-json-path"],
      outputDir: flags["output-dir"] || "zig-out/node",
      npmDir: flags["npm-dir"],
      buildOutputDir: flags["build-output-dir"],
    }),
  );
}

async function main() {
  const [command, ...argv] = process.argv.slice(2);
  if (!command || command === "-h" || command === "--help" || command === "help") {
    printHelp();
    return;
  }

  switch (command) {
    case "new":
      commandNew(argv);
      break;
    case "build":
      await commandBuild(argv);
      break;
    case "dts":
      commandDts(argv);
      break;
    case "create-npm-dirs":
      await commandCreateNpmDirs(argv);
      break;
    case "artifacts":
      await commandArtifacts(argv);
      break;
    case "pre-publish":
      await commandPrePublish(argv);
      break;
    case "package":
      await commandPackage(argv);
      break;
    default:
      fail(`unknown command: ${command}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
