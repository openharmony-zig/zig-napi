#!/usr/bin/env node

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { NapiCli } = require("@napi-rs/cli");

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

function commandBuild(argv) {
  const { flags, passthrough } = parseArgs(argv);
  const cwd = path.resolve(process.cwd(), flags.cwd || ".");
  const args = ["build"];
  if (flags.release) args.push("-Doptimize=ReleaseFast");
  if (flags.target) args.push(`-Dtarget=${flags.target}`);
  args.push(...passthrough);
  run("zig", args, { cwd });
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
  commandBuild([
    "--cwd",
    cwd,
    ...(flags.release ? ["--release"] : []),
    ...(flags.target ? ["--target", flags.target] : []),
  ]);
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
      commandBuild(argv);
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
