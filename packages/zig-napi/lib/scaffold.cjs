"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createNewCommand, parseTriple } = require("@napi-rs/cli");

// Adapted from napi-rs 3.10.7 utils/version.ts (not a public export).
const nodeVersions = [
  null,
  ["8.6.0", "9.0.0", "10.0.0"],
  ["8.10.0", "9.3.0", "10.0.0"],
  ["6.14.2", "8.11.2", "9.11.0", "10.0.0"],
  ["10.16.0", "11.8.0", "12.0.0"],
  ["10.17.0", "12.11.0", "13.0.0"],
  ["10.20.0", "12.17.0", "14.0.0"],
  ["10.23.0", "12.19.0", "14.12.0", "15.0.0"],
  ["12.22.0", "14.17.0", "15.12.0", "16.0.0"],
  ["18.17.0", "20.3.0", "21.1.0"],
  ["22.14.0", "23.6.0"],
];

function options(flags) {
  const defaults = createNewCommand([]).getOptions();
  const result = {
    ...defaults,
    ...Object.fromEntries(Object.entries(flags).filter(([, v]) => v !== undefined)),
  };
  result.minNodeApiVersion = Number(flags.minNodeApi ?? defaults.minNodeApiVersion);
  if (!Number.isInteger(result.minNodeApiVersion) || !nodeVersions[result.minNodeApiVersion])
    throw new Error("--min-node-api must be an integer from 1 to 10");
  if (!["yarn", "pnpm"].includes(result.packageManager))
    throw new Error("--package-manager must be yarn or pnpm, as supported by napi-rs");
  if (result.testFramework !== "ava")
    throw new Error("--test-framework currently supports ava only");
  return result;
}

function nodeEngine(version) {
  return nodeVersions[version]
    .map((v, i, list) => `${i ? `< ${Number(list[i - 1].split(".")[0]) + 1} || ` : ""}>= ${v}`)
    .join(" ");
}

function workflow(targets, binaryName, packageManager) {
  const matrix = targets.map((target) => {
    const parsed = parseTriple(target);
    return {
      target,
      platform: parsed.platformArchABI,
      os:
        parsed.platform === "darwin"
          ? "macos-latest"
          : parsed.platform === "win32"
            ? "windows-latest"
            : "ubuntu-latest",
      arch: parsed.arch,
      wasi: parsed.platform === "wasi",
      universal: parsed.arch === "universal",
    };
  });
  const install = packageManager === "pnpm" ? "pnpm install --no-frozen-lockfile" : "yarn install";
  const exec = packageManager === "pnpm" ? "pnpm exec" : "yarn";
  // JSON is a YAML-compatible scalar/collection format; serializing the matrix
  // keeps package names and target strings out of shell/YAML interpolation.
  return `name: CI
on: [push, pull_request, workflow_dispatch]
permissions:
  contents: read
env:
  APP_NAME: ${JSON.stringify(binaryName)}
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include: ${JSON.stringify(matrix)}
    runs-on: \${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '24'
      - uses: mlugg/setup-zig@v2
        with:
          version: '0.17.0'
      - run: corepack enable
      - run: ${install}
      - name: Windows Node import library
        if: runner.os == 'Windows'
        shell: bash
        env:
          NODE_ARCH: \${{ matrix.arch }}
        run: |
          node -e 'const fs=require("node:fs");(async()=>{const r=await fetch("https://nodejs.org/download/release/"+process.version+"/win-"+(process.env.NODE_ARCH==="ia32"?"x86":process.env.NODE_ARCH)+"/node.lib");if(!r.ok)throw new Error("node.lib: "+r.status);fs.writeFileSync("node.lib",Buffer.from(await r.arrayBuffer()));fs.appendFileSync(process.env.GITHUB_ENV,"NODE_LIB_FILE="+require("node:path").resolve("node.lib")+"\\n");})().catch(e=>{console.error(e);process.exitCode=1})'
      - name: Build
        if: \${{ !matrix.universal }}
        env:
          ADDON_TARGET: \${{ matrix.target }}
        run: ${exec} zig-napi build --platform --release --target "$ADDON_TARGET"
        shell: bash
      - name: Universal macOS binary
        if: matrix.universal
        run: |
          ${exec} zig-napi build --platform --release --target aarch64-apple-darwin
          ${exec} zig-napi build --platform --release --target x86_64-apple-darwin
          ${exec} zig-napi universalize
      - name: Test host or WASI binding
        shell: bash
        env:
          ADDON_PLATFORM: \${{ matrix.platform }}
          ADDON_WASI: \${{ matrix.wasi }}
        run: |
          if [ "$ADDON_WASI" = true ]; then
            NAPI_RS_FORCE_WASI=error NAPI_RS_WASI_FLAVOR="$ADDON_PLATFORM" ${packageManager} test:run
          elif node -e 'const p=process.env.ADDON_PLATFORM;process.exit(p===process.platform+"-"+process.arch+(process.platform==="linux"?"-gnu":process.platform==="win32"?"-msvc":"")||p==="darwin-universal"?0:1)'; then
            ${packageManager} test:run
          fi
      - uses: actions/upload-artifact@v4
        with:
          name: addon-\${{ matrix.platform }}
          path: |
            \${{ env.APP_NAME }}.\${{ matrix.platform }}.node
            \${{ env.APP_NAME }}.\${{ matrix.platform }}.wasm
            *.cjs
            *.js
            *.mjs
            *.d.ts
            *.d.cts
  packages:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '24'
      - run: corepack enable
      - run: ${install}
      - uses: actions/download-artifact@v4
        with:
          pattern: addon-*
          path: artifacts
      - run: ${exec} zig-napi artifacts --output-dir artifacts
      - uses: actions/upload-artifact@v4
        with:
          name: npm-packages
          path: npm/
`;
}

function configure(directory, flags, targets, binaryName) {
  const file = path.join(directory, "package.json");
  const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
  pkg.license = flags.license;
  pkg.packageManager = flags.packageManager === "pnpm" ? "pnpm@10.24.0" : "yarn@4.9.2";
  pkg.napi.npmClient = flags.packageManager;
  pkg.engines.node =
    targets.every((t) => parseTriple(t).platform === "wasi") && flags.minNodeApiVersion < 10
      ? "^20.19.0 || ^22.13.0 || >=23.5.0"
      : nodeEngine(flags.minNodeApiVersion);
  pkg.zigNapi = { typeDef: flags.enableTypeDef, managedZigDependency: !flags.zigNapi };
  pkg.scripts.build = "zig-napi build --platform --release";
  pkg.scripts["build:debug"] = "zig-napi build --platform";
  if (!flags.enableTypeDef) {
    delete pkg.types;
    pkg.files = pkg.files.filter((file) => !/\.d\.(?:ts|cts|mts)$/.test(file));
    fs.rmSync(path.join(directory, "index.d.ts"), { force: true });
  }
  fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
  const buildPath = path.join(directory, "build.zig");
  let source = fs
    .readFileSync(buildPath, "utf8")
    .replaceAll(".version = .v8", `.version = .v${flags.minNodeApiVersion}`);
  if (!flags.enableTypeDef)
    source = source.replace(
      /\n    const dts = [\s\S]*?b\.getInstallStep\(\)\.dependOn\(&dts\.step\);\n/,
      "\n",
    );
  fs.writeFileSync(buildPath, source);
  if (flags.packageManager === "yarn")
    fs.writeFileSync(path.join(directory, ".yarnrc.yml"), "nodeLinker: node-modules\n");
  else fs.writeFileSync(path.join(directory, "pnpm-workspace.yaml"), "packages:\n  - '.'\n");
  fs.writeFileSync(
    path.join(directory, ".gitignore"),
    "node_modules/\n.zig-cache/\nzig-out/\nartifacts/\n*.node\n*.wasm\n",
  );
  if (flags.enableGithubActions) {
    const workflows = path.join(directory, ".github", "workflows");
    fs.mkdirSync(workflows, { recursive: true });
    fs.writeFileSync(
      path.join(workflows, "CI.yml"),
      workflow(targets, binaryName, flags.packageManager),
    );
  }
}

// A scaffold can be created by a global CLI and then checked out elsewhere.
// Rebase only the dependency we own to the CLI actually running the build.
// Explicit --zig-napi dependencies always remain under the user's control.
function resolveDependency(directory, dependency, pkg) {
  if (!pkg.zigNapi?.managedZigDependency) return;
  const manifest = path.join(directory, "build.zig.zon");
  const source = fs.readFileSync(manifest, "utf8");
  const updated = source.replace(
    /(\.@"zig-napi"\s*=\s*\.\{\s*\.path\s*=\s*)"(?:[^"\\]|\\.)*"/,
    (_match, prefix) => prefix + JSON.stringify(dependency.split(path.sep).join("/")),
  );
  if (updated !== source) fs.writeFileSync(manifest, updated);
}

module.exports = { options, configure, workflow, nodeEngine, resolveDependency };
