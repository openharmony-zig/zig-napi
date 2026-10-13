const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const api = require("@napi-rs/cli");
const cli = path.resolve(__dirname, "../bin/zig-napi.js");

function fixture(t, napi = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-parity-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.writeFileSync(
    path.join(dir, "package.json"),
    JSON.stringify({
      name: "parity",
      version: "1.2.3",
      napi: { binaryName: "addon", targets: ["aarch64-apple-darwin"], ...napi },
    }),
  );
  return dir;
}

function invoke(args, cwd, preload) {
  return spawnSync(process.execPath, [...(preload ? ["--require", preload] : []), cli, ...args], {
    cwd,
    encoding: "utf8",
    timeout: 30_000,
  });
}
function success(result) {
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return result.stdout;
}

// Stub only process execution. Argument parsing, configuration, generation,
// packaging and declaration processing are the actual installed APIs.
function fakeZig(dir) {
  const file = path.join(dir, "zig-preload.cjs");
  fs.writeFileSync(
    file,
    `
const fs = require('node:fs'), path = require('node:path');
const cp = require('node:child_process'), original = cp.spawnSync;
cp.spawnSync = function(command, args, opts) {
  if (command !== 'zig') return original.apply(this, arguments);
  fs.appendFileSync(${JSON.stringify(path.join(dir, "zig.log"))}, JSON.stringify(args)+'\\n');
  const prefix = args.includes('--prefix') ? args[args.indexOf('--prefix') + 1] : 'zig-out';
  const target = args.find(a=>a.startsWith('-Dtarget='));
  const platform = target?.includes('x86_64-linux') ? 'linux-x64-gnu' : ${JSON.stringify(require("../lib/targets.cjs").platformId())};
  const output = path.resolve(opts.cwd, prefix, 'node');
  fs.mkdirSync(output, {recursive:true});
  fs.writeFileSync(path.join(output, 'addon.'+platform+'.node'), 'binary');
  return {status:0, stdout:'', stderr:''};
};
`,
  );
  return file;
}

function writeEmnapiPackages(dir, names) {
  for (const name of names) {
    const directory = path.join(dir, "node_modules", name);
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(
      path.join(directory, "package.json"),
      JSON.stringify({ name, version: "2.0.0-alpha.5" }),
    );
  }
}

test("all upstream command options have an adapter or an explicit Cargo/OHOS boundary", (t) => {
  const dir = fixture(t);
  const excluded = new Set(require("../lib/build-output.cjs").cargoOptions);
  for (const definition of api.cli.definitions()) {
    const command = definition.path.split(" ").at(-1);
    const help = success(invoke([command, "--help"], dir));
    for (const option of definition.options) {
      for (const name of option.nameSet) {
        if (command === "build" && excluded.has(name)) continue;
        assert.ok(help.includes(name), `${command} is missing ${name}`);
      }
    }
  }
  assert.equal(success(invoke(["-v"], dir)).trim(), require("../package.json").version);
  assert.match(success(invoke(["prepublish", "--help"], dir)), /--root-publisher/);
});

test("delegated commands forward public parser aliases, defaults and publish options", (t) => {
  const dir = fixture(t);
  const preload = path.join(dir, "api-preload.cjs");
  fs.writeFileSync(
    preload,
    `
const api = require(${JSON.stringify(require.resolve("@napi-rs/cli"))});
const Original = api.NapiCli;
api.NapiCli = class extends Original {
  constructor() { super(); for (const name of ['createNpmDirs','artifacts','prePublish','version','universalize'])
    this[name] = async (options) => console.log('CAPTURE:'+JSON.stringify({name, options})); }
};
`,
  );
  const cases = [
    [
      "create-npm-dirs",
      ["--npm-dir", "platforms", "--dry-run"],
      "createNpmDirs",
      { npmDir: "platforms", dryRun: true },
    ],
    [
      "artifacts",
      ["-d", "downloads", "--build-output-dir", "dist"],
      "artifacts",
      { outputDir: "downloads", buildOutputDir: "dist" },
    ],
    [
      "prepublish",
      [
        "-p",
        "platforms",
        "--tagstyle",
        "npm",
        "--root-publisher",
        "pnpm",
        "--no-gh-release",
        "--skip-optional-publish",
        "--dry-run",
      ],
      "prePublish",
      {
        npmDir: "platforms",
        tagStyle: "npm",
        rootPublisher: "pnpm",
        ghRelease: false,
        skipOptionalPublish: true,
        dryRun: true,
      },
    ],
    ["version", [], "version", { npmDir: "npm" }],
    ["universalize", ["-o", "dist"], "universalize", { outputDir: "dist" }],
  ];
  for (const [command, args, name, expected] of cases) {
    const result = success(invoke([command, ...args, "--cwd", dir], dir, preload));
    const capture = JSON.parse(result.match(/CAPTURE:(.*)/)[1]);
    assert.equal(capture.name, name);
    for (const [key, value] of Object.entries(expected))
      assert.equal(capture.options[key], value, `${command}.${key}`);
    assert.equal(capture.options.cwd, dir);
  }
});

test("new and package dry-run do not invoke Zig or create project files", (t) => {
  const dir = fixture(t),
    preload = fakeZig(dir);
  const target = path.join(dir, "absent");
  success(
    invoke(
      [
        "new",
        target,
        "--no-interactive",
        "--dry-run",
        "-n",
        "planned",
        "-v",
        "9",
        "--enable-type-def=false",
      ],
      dir,
      preload,
    ),
  );
  assert.equal(fs.existsSync(target), false);
  success(invoke(["package", "--dry-run"], dir, preload));
  assert.equal(fs.existsSync(path.join(dir, "npm")), false);
  assert.equal(fs.existsSync(path.join(dir, "zig.log")), false);
});

test("new applies NAPI, license, package manager, declaration and CI choices", (t) => {
  const dir = fixture(t),
    preload = fakeZig(dir);
  const project = path.join(dir, "new-addon");
  success(
    invoke(
      [
        "new",
        project,
        "--no-interactive",
        "-n",
        "@test/project",
        "-v",
        "9",
        "-l",
        "Apache-2.0",
        "--package-manager",
        "pnpm",
        "--enable-type-def=false",
        "--enable-github-actions=false",
        "-t",
        "aarch64-apple-darwin,x86_64-unknown-linux-gnu",
      ],
      dir,
      preload,
    ),
  );
  const pkg = JSON.parse(fs.readFileSync(path.join(project, "package.json")));
  assert.equal(pkg.license, "Apache-2.0");
  assert.equal(pkg.engines.node, ">= 18.17.0 < 19 || >= 20.3.0 < 21 || >= 21.1.0");
  assert.equal(pkg.napi.npmClient, "pnpm");
  assert.match(pkg.packageManager, /^pnpm@/);
  assert.equal(pkg.types, undefined);
  assert.equal(fs.existsSync(path.join(project, "index.d.ts")), false);
  assert.equal(fs.existsSync(path.join(project, ".github")), false);
  assert.deepEqual(fs.readdirSync(path.join(project, "npm")).sort(), [
    "darwin-arm64",
    "linux-x64-gnu",
  ]);
  const build = fs.readFileSync(path.join(project, "build.zig"), "utf8");
  assert.match(build, /\.version = \.v9/);
  assert.doesNotMatch(build, /generateTypeDefinition/);
  const second = path.join(dir, "with-ci");
  success(
    invoke(
      ["new", second, "--no-interactive", "-t", "aarch64-apple-darwin,x86_64-pc-windows-msvc"],
      dir,
      preload,
    ),
  );
  const workflow = fs.readFileSync(path.join(second, ".github/workflows/CI.yml"), "utf8");
  const matrix = JSON.parse(workflow.match(/include: (.*)/)[1]);
  assert.deepEqual(
    matrix.map((row) => row.platform),
    ["darwin-arm64", "win32-x64-msvc"],
  );
  assert.match(workflow, /mlugg\/setup-zig@v2/);
  assert.match(workflow, /version: '0.17.0'/);
  assert.match(workflow, /zig-napi artifacts --output-dir artifacts/);
  assert.match(fs.readFileSync(path.join(second, "build.zig"), "utf8"), /\.version = \.v4/);
});

test("build options affect native artifacts, declarations, output paths and pipe inputs", (t) => {
  const dir = fixture(t),
    preload = fakeZig(dir);
  fs.writeFileSync(
    path.join(dir, "index.d.ts"),
    '/* auto-generated by zig-addon */\n/* eslint-disable */\nexport declare function add(a:number,b:number):number;\nexport const enum Code { OK = 0 }\nexport const enum Text { A = "a", B = "b" }\n',
  );
  fs.writeFileSync(
    path.join(dir, "pipe.cjs"),
    'require("node:fs").appendFileSync("pipe.log", process.argv[2]+"\\n")',
  );
  success(
    invoke(
      [
        "build",
        "--platform",
        "-r",
        "-s",
        "-v",
        "-x",
        "-t",
        "x86_64-unknown-linux-gnu",
        "--target-dir",
        "cache with spaces",
        "-o",
        "dist with spaces",
        "--js",
        "loader.cjs",
        "--dts",
        "types/api.d.ts",
        "--dts-header",
        "// custom\n",
        "--no-const-enum",
        "--no-dts-cache",
        "--js-package-name",
        "@test/platform",
        "--pipe",
        "node pipe.cjs",
      ],
      dir,
      preload,
    ),
  );
  const output = path.join(dir, "dist with spaces");
  assert.equal(fs.readFileSync(path.join(output, "addon.linux-x64-gnu.node"), "utf8"), "binary");
  assert.match(
    fs.readFileSync(path.join(output, "loader.cjs"), "utf8"),
    /@test\/platform-linux-x64-gnu/,
  );
  const types = fs.readFileSync(path.join(output, "types/api.d.ts"), "utf8");
  assert.match(types, /^\/\/ custom\n/);
  assert.doesNotMatch(types, /const enum/);
  assert.match(types, /type Text = "a" \| "b"/);
  assert.match(types, /__napiBindingTarget/);
  const args = JSON.parse(fs.readFileSync(path.join(dir, "zig.log"), "utf8").trim());
  for (const arg of [
    "-Dtarget=x86_64-linux-gnu",
    "-Dstrip=true",
    "-Ddts-cache=false",
    "-Doptimize=fast",
  ])
    assert.ok(args.includes(arg));
  const piped = fs.readFileSync(path.join(dir, "pipe.log"), "utf8").trim().split("\n");
  assert.equal(piped.length, 3);
  assert.ok(piped.every((file) => fs.existsSync(file)));
  success(
    invoke(["build", "--no-platform", "--no-js", "--no-dts-header", "-o", "plain"], dir, preload),
  );
  assert.equal(fs.existsSync(path.join(dir, "plain/addon.node")), true);
  assert.equal(fs.existsSync(path.join(dir, "plain/index.js")), false);
  assert.doesNotMatch(
    fs.readFileSync(path.join(dir, "plain/index.d.ts"), "utf8"),
    /auto-generated|__napiBindingTarget/,
  );
});

test("mixed targets build natively with a partial emnapi install and no WASI flags", (t) => {
  for (const targetArgs of [
    ["--target", "aarch64-apple-darwin"],
    [],
    ["--", "-Dtarget=aarch64-macos"],
  ]) {
    const dir = fixture(t, {
      targets: ["aarch64-apple-darwin", "wasm32-wasip1-threads", "wasm32-wasip1"],
      wasm: { initialMemory: 1024, threadlessInitialMemory: 128, maximumMemory: 2048 },
    });
    const preload = fakeZig(dir);
    writeEmnapiPackages(dir, ["emnapi"]);
    const installedOutput = path.join(dir, "zig-out", "node");
    fs.mkdirSync(installedOutput, { recursive: true });
    for (const platform of ["wasm32-wasi", "wasm32-wasip1"]) {
      fs.writeFileSync(path.join(installedOutput, `addon.${platform}.wasm`), "wasm");
    }

    const result = invoke(["build", "--platform", ...targetArgs], dir, preload);
    success(result);
    assert.doesNotMatch(result.stderr, /emnapi/);
    const args = JSON.parse(fs.readFileSync(path.join(dir, "zig.log"), "utf8").trim());
    assert.ok(!args.some((arg) => arg.startsWith("-Dwasi-")), args.join(" "));
    for (const platform of ["wasm32-wasi", "wasm32-wasip1"]) {
      assert.equal(fs.readFileSync(path.join(dir, `addon.${platform}.wasm`), "utf8"), "wasm");
    }
    assert.ok(fs.existsSync(path.join(dir, "addon.wasi.cjs")));
    assert.ok(fs.existsSync(path.join(dir, "addon.wasip1.cjs")));
    const binding = fs.readFileSync(path.join(dir, "index.js"), "utf8");
    assert.match(binding, /parity-wasm32-wasi/);
    assert.match(binding, /parity-wasm32-wasip1/);
  }
});

test("WASI compile flavors follow explicit targets and passthrough atomics", (t) => {
  const cases = [
    { args: ["--target", "wasm32-wasip1-threads"], initialMemory: 1024 },
    { args: ["--target", "wasm32-wasip1"], initialMemory: 128 },
    { args: ["--", "-Dtarget=wasm32-wasi"], initialMemory: 128 },
    { args: ["--", "-Dtarget=wasm32-wasi", "-Dcpu=baseline"], initialMemory: 128 },
    {
      args: ["--", "-Dtarget=wasm32-wasi", "-Dcpu=baseline+atomics+bulk_memory+mutable_globals"],
      initialMemory: 1024,
    },
    {
      args: ["--", "-Dtarget", "wasm32-wasi", "-Dcpu", "baseline+atomics"],
      initialMemory: 1024,
    },
    {
      args: ["--target", "wasm32-wasip1-threads", "--", "-Dtarget=wasm32-wasi"],
      initialMemory: 1024,
    },
    {
      args: ["--", "-Dtarget=wasm32-wasi", "-Dcpu=baseline+atomics", "-Dcpu=baseline"],
      initialMemory: 128,
    },
    {
      args: ["--target", "aarch64-apple-darwin", "--", "-Dtarget=wasm32-wasi", "-Dcpu=baseline"],
      initialMemory: 128,
    },
  ];
  for (const { args: targetArgs, initialMemory } of cases) {
    const dir = fixture(t, {
      targets: ["aarch64-apple-darwin", "wasm32-wasip1-threads", "wasm32-wasip1"],
      wasm: { initialMemory: 1024, threadlessInitialMemory: 128, maximumMemory: 2048 },
    });
    const preload = fakeZig(dir);
    writeEmnapiPackages(dir, ["emnapi"]);
    const partial = invoke(["build", "--platform", ...targetArgs], dir, preload);
    assert.notEqual(partial.status, 0, targetArgs.join(" "));
    assert.match(partial.stderr, /WASI builds need.*missing @emnapi\/core, @emnapi\/runtime/);
    assert.equal(fs.existsSync(path.join(dir, "zig.log")), false);

    writeEmnapiPackages(dir, ["@emnapi/core", "@emnapi/runtime"]);
    success(invoke(["build", "--platform", ...targetArgs], dir, preload));
    const args = JSON.parse(fs.readFileSync(path.join(dir, "zig.log"), "utf8").trim());
    assert.ok(args.includes(`-Dwasi-initial-memory-pages=${initialMemory}`), args.join(" "));
    assert.ok(args.includes("-Dwasi-max-memory-pages=2048"), args.join(" "));
  }
});

test("JS binding false values disable output while true values remain filenames", (t) => {
  for (const option of ["js", "js-binding"]) {
    for (const value of ["false", "true"]) {
      const dir = fixture(t),
        preload = fakeZig(dir);
      fs.writeFileSync(
        path.join(dir, "index.d.ts"),
        "export declare function add(a: number, b: number): number;\n",
      );
      success(invoke(["build", "--platform", `--${option}=${value}`], dir, preload));
      assert.equal(fs.existsSync(path.join(dir, "index.js")), false);
      assert.equal(fs.existsSync(path.join(dir, "false")), false);
      assert.equal(fs.existsSync(path.join(dir, "true")), value === "true");
      assert.ok(
        fs.existsSync(path.join(dir, `addon.${require("../lib/targets.cjs").platformId()}.node`)),
      );
    }
  }
});

test("cached declarations can change enum and header options without losing exports", (t) => {
  const dir = fixture(t),
    preload = fakeZig(dir);
  fs.writeFileSync(
    path.join(dir, "index.d.ts"),
    'export declare const enum Text { A = "a", B = "b" }\n',
  );
  success(
    invoke(["build", "--platform", "--no-const-enum", "--dts-header", "// first\n"], dir, preload),
  );
  assert.match(fs.readFileSync(path.join(dir, "index.d.ts"), "utf8"), /type Text = "a" \| "b"/);
  success(
    invoke(
      [
        "build",
        "--platform",
        "--no-const-enum",
        "--runtime-string-enum",
        "--dts-header",
        "// second\n",
      ],
      dir,
      preload,
    ),
  );
  let types = fs.readFileSync(path.join(dir, "index.d.ts"), "utf8");
  assert.match(types, /enum Text/);
  assert.doesNotMatch(types, /const enum|first/);
  success(
    invoke(
      ["build", "--platform", "--const-enum", "--no-dts-header", "--esm", "--js", "index.mjs"],
      dir,
      preload,
    ),
  );
  types = fs.readFileSync(path.join(dir, "index.d.ts"), "utf8");
  assert.match(types, /const enum Text/);
  assert.doesNotMatch(types, /first|second/);
  const binding = fs.readFileSync(path.join(dir, "index.mjs"), "utf8");
  assert.match(binding, /export \{ Text \}/);
  assert.doesNotMatch(binding, /export const enum/);
  success(
    spawnSync(process.execPath, ["--check", path.join(dir, "index.mjs")], { encoding: "utf8" }),
  );
});

test("external config is merged by napi-rs and invalid build options fail before invoking Zig", (t) => {
  const dir = fixture(t),
    preload = fakeZig(dir);
  fs.writeFileSync(path.join(dir, "config.json"), JSON.stringify({ packageName: "merged" }));
  success(invoke(["create-npm-dirs", "-c", "config.json"], dir));
  const platform = JSON.parse(fs.readFileSync(path.join(dir, "npm/darwin-arm64/package.json")));
  assert.equal(platform.name, "merged-darwin-arm64");
  assert.equal(platform.main, "addon.darwin-arm64.node");
  for (const args of [
    ["--features", "foo"],
    ["--profile", "release"],
    ["--manifest-path", "Cargo.toml"],
    ["--esm", "--commonjs"],
    ["--watch", "--use-cross"],
  ]) {
    const result = invoke(["build", ...args], dir, preload);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Cargo|Choose one build format/);
  }
  assert.equal(fs.existsSync(path.join(dir, "zig.log")), false);
});

test("rename keeps root name and platform package prefix independent", (t) => {
  const dir = fixture(t);
  success(invoke(["create-npm-dirs"], dir));
  success(
    invoke(
      [
        "rename",
        "-n",
        "root-name",
        "--package-name",
        "@test/platform",
        "--repository",
        "https://example.com/project",
        "--description",
        "updated",
      ],
      dir,
    ),
  );
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json")));
  assert.equal(pkg.name, "root-name");
  assert.equal(pkg.napi.packageName, "@test/platform");
  assert.equal(pkg.repository, "https://example.com/project");
  assert.equal(pkg.description, "updated");
  assert.equal(
    JSON.parse(fs.readFileSync(path.join(dir, "npm/darwin-arm64/package.json"))).name,
    "@test/platform-darwin-arm64",
  );
});

for (const customPaths of [false, true]) {
  test(`rename dry-run matches napi-rs writes with ${customPaths ? "custom relative" : "default"} paths`, (t) => {
    const preview = fixture(t);
    const actual = fixture(t);
    const packageJsonPath = customPaths ? "metadata/addon.json" : "package.json";
    const configPath = customPaths ? "config/napi.json" : undefined;
    const npmDir = customPaths ? "platforms" : "npm";
    const platformName = "parity-darwin-arm64";
    for (const directory of [preview, actual]) {
      const napi = {
        binaryName: "addon",
        packageName: "parity",
        targets: ["aarch64-apple-darwin"],
      };
      const pkg = {
        name: "parity",
        version: "1.2.3",
        napi: configPath ? undefined : napi,
        main: "index.cjs",
        dependencies: { [platformName]: "1.2.3" },
        devDependencies: { [platformName]: "1.2.3" },
        optionalDependencies: { [platformName]: "1.2.3" },
        overrides: { [platformName]: "1.2.3" },
        resolutions: { [platformName]: "1.2.3" },
        pnpm: { overrides: { [platformName]: "1.2.3" } },
      };
      if (customPaths) {
        fs.unlinkSync(path.join(directory, "package.json"));
        fs.writeFileSync(path.join(directory, "pnpm-workspace.yaml"), "packages: []\n");
      }
      fs.mkdirSync(path.dirname(path.join(directory, packageJsonPath)), { recursive: true });
      fs.writeFileSync(path.join(directory, packageJsonPath), JSON.stringify(pkg));
      if (configPath) {
        fs.mkdirSync(path.dirname(path.join(directory, configPath)), { recursive: true });
        fs.writeFileSync(path.join(directory, configPath), JSON.stringify(napi));
      }
      fs.mkdirSync(path.join(directory, npmDir, "darwin-arm64"), { recursive: true });
      fs.writeFileSync(
        path.join(directory, npmDir, "darwin-arm64/package.json"),
        JSON.stringify({ name: platformName, version: "1.2.3", main: "addon.darwin-arm64.node" }),
      );
      fs.writeFileSync(
        path.join(directory, "index.cjs"),
        `module.exports = require("${platformName}");\n`,
      );
      for (const excluded of ["node_modules", ".git", ".zig-cache", "zig-out", ".tmp-fixture"]) {
        fs.mkdirSync(path.join(directory, excluded));
        fs.writeFileSync(path.join(directory, excluded, "untouched"), "keep");
      }
      fs.symlinkSync("index.cjs", path.join(directory, "linked.cjs"));
    }
    const snapshot = (directory) => {
      const files = new Map();
      const walk = (current) => {
        for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
          const file = path.join(current, entry.name);
          const relative = path.relative(directory, file);
          if (entry.isDirectory()) walk(file);
          else if (entry.isFile()) files.set(relative, fs.readFileSync(file, "utf8"));
          else if (entry.isSymbolicLink()) files.set(relative, { link: fs.readlinkSync(file) });
        }
      };
      walk(directory);
      return files;
    };
    const before = snapshot(preview);
    const args = [
      "rename",
      "--package-name",
      "renamed",
      "--package-json-path",
      packageJsonPath,
      "--npm-dir",
      npmDir,
    ];
    if (configPath) args.push("--config-path", configPath);
    const plan = JSON.parse(success(invoke([...args, "--dry-run"], preview)));
    assert.deepEqual(snapshot(preview), before, "dry-run must leave every original file unchanged");
    const plannedPackage = JSON.parse(
      plan.writes.find(({ file }) => file === path.join(fs.realpathSync(preview), packageJsonPath))
        .content,
    );
    assert.deepEqual(plannedPackage.dependencies, { "renamed-darwin-arm64": "1.2.3" });
    success(invoke(args, actual));
    const after = snapshot(actual);
    const writes = new Map(
      plan.writes.map(({ file, content }) => {
        assert.equal(path.isAbsolute(file), true);
        const relative = path.relative(fs.realpathSync(preview), file);
        assert.ok(!relative.startsWith(".."), file);
        assert.equal(content, after.get(relative), relative);
        return [relative, content];
      }),
    );
    for (const [file, content] of after) {
      if (typeof content === "string" && content !== before.get(file))
        assert.ok(writes.has(file), `missing preview write: ${file}`);
    }
    assert.deepEqual(plan.renames, []);
    assert.equal(writes.get(packageJsonPath).includes('"renamed-darwin-arm64"'), true);
  });
}

test("rename dry-run isolates napi-rs output, paths and cleanup in a disposable copy", (t) => {
  const dir = fixture(t);
  const original = fs.readFileSync(path.join(dir, "package.json"), "utf8");
  const preload = path.join(dir, "api-preload.cjs");
  for (const excluded of ["node_modules", ".git", ".zig-cache", "zig-out", ".tmp-fixture"]) {
    fs.mkdirSync(path.join(dir, excluded));
    fs.writeFileSync(path.join(dir, excluded, "keep"), "untouched");
  }
  fs.symlinkSync("package.json", path.join(dir, "linked.json"));
  fs.mkdirSync(path.join(dir, "config"));
  fs.writeFileSync(
    path.join(dir, "config/napi.json"),
    JSON.stringify({ binaryName: "addon", targets: ["aarch64-apple-darwin"] }),
  );
  fs.writeFileSync(path.join(dir, "removed.txt"), "old");
  fs.writeFileSync(
    preload,
    `
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const api = require(${JSON.stringify(require.resolve("@napi-rs/cli"))});
const Original = api.NapiCli;
api.NapiCli = class extends Original {
  constructor() { super(); this.rename = async (options) => {
    console.error("COPY:" + options.cwd);
    assert.notEqual(options.cwd, ${JSON.stringify(fs.realpathSync(dir))});
    for (const name of ["node_modules", ".git", ".zig-cache", "zig-out", ".tmp-fixture", "linked.json"])
      assert.equal(fs.existsSync(path.join(options.cwd, name)), false, name);
    for (const [key, relative] of Object.entries({packageJsonPath:"package.json", configPath:"config/napi.json", npmDir:"platforms"}))
      assert.equal(path.resolve(options.cwd, options[key]), path.join(options.cwd, relative));
    console.log("upstream log");
    await new Promise(resolve => process.stdout.write("upstream write\\n", resolve));
    fs.writeFileSync(path.join(options.cwd, "added.txt"), "from napi-rs");
    fs.unlinkSync(path.join(options.cwd, "removed.txt"));
    if (options.description === "fail") throw new Error("rename failed in copy");
  }; }
};
`,
  );
  const args = [
    "rename",
    "--dry-run",
    "--package-name",
    "renamed",
    "--package-json-path",
    path.join(dir, "package.json"),
    "--config-path",
    path.join(dir, "config/napi.json"),
    "--npm-dir",
    path.join(dir, "platforms"),
  ];
  const result = invoke(args, dir, preload);
  const plan = JSON.parse(success(result));
  assert.deepEqual(plan, {
    writes: [{ file: path.join(fs.realpathSync(dir), "added.txt"), content: "from napi-rs" }],
    renames: [],
    removals: [path.join(fs.realpathSync(dir), "removed.txt")],
  });
  assert.equal(fs.existsSync(result.stderr.match(/COPY:(.*)/)[1]), false);
  assert.equal(fs.readFileSync(path.join(dir, "package.json"), "utf8"), original);
  assert.equal(fs.readFileSync(path.join(dir, "removed.txt"), "utf8"), "old");
  assert.equal(fs.existsSync(path.join(dir, "added.txt")), false);
  const failed = invoke([...args, "--description", "fail"], dir, preload);
  assert.notEqual(failed.status, 0);
  assert.equal(failed.stdout, "");
  assert.match(failed.stderr, /rename failed in copy/);
  assert.equal(fs.existsSync(failed.stderr.match(/COPY:(.*)/)[1]), false);
  assert.equal(fs.readFileSync(path.join(dir, "removed.txt"), "utf8"), "old");
  assert.equal(fs.existsSync(path.join(dir, "added.txt")), false);
});
