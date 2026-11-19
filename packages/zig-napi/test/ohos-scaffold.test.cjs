const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const cli = path.resolve(__dirname, "../bin/zig-napi.js");
const checkout = path.resolve(__dirname, "../../..");

function scaffold(t, ...flags) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-ohos-"));
  t.after(() => fs.rmSync(scratch, { recursive: true, force: true }));
  const project = path.join(scratch, "library with spaces");
  const args = [
    "new",
    project,
    "--template",
    "ohos",
    "--no-interactive",
    "--name",
    "@sample/demo",
    "--addon",
    "demo_native",
    ...flags,
  ];
  return {
    project,
    generate: () => execFileSync(process.execPath, [cli, ...args], { encoding: "utf8" }),
  };
}

test("the OHOS template plans and generates a DevEco HAR with matching ArkTS and Zig module names", (t) => {
  const dry = scaffold(t, "--dry-run");
  const plan = JSON.parse(dry.generate());
  assert.equal(plan.template, "ohos");
  assert.deepEqual(plan.targets, ["aarch64-linux-ohos", "arm-linux-ohoseabi", "x86_64-linux-ohos"]);
  assert.equal(fs.existsSync(dry.project), false);

  const { project, generate } = scaffold(
    t,
    "--license",
    "Apache-2.0",
    "--no-enable-github-actions",
  );
  generate();
  const read = (file) => fs.readFileSync(path.join(project, file), "utf8");
  const pkg = JSON.parse(read("package/oh-package.json5"));
  assert.equal(pkg.name, "@sample/demo");
  assert.equal(pkg.license, "Apache-2.0");
  assert.equal(pkg.dependencies["libdemo_native.so"], "file:./types");
  assert.match(read("package/types/oh-package.json5"), /"name": ['"]libdemo_native\.so['"]/);
  assert.match(read("package/" + pkg.main), /from "libdemo_native\.so"/);
  assert.match(read("package/" + pkg.types), /function add\(/);
  assert.match(read("src/lib.zig"), /NODE_API_MODULE\("demo_native"/);
  assert.match(read("build.zig.zon"), /archive\/refs\/tags\/0\.2\.0\.tar\.gz/);
  assert.match(read("package/src/main/module.json5"), /"type": ['"]har['"]/);
  for (const name of ["npm", "node_modules", "package.json", ".github"]) {
    assert.equal(fs.existsSync(path.join(project, name)), false, name);
  }
});

test(
  "the generated OHOS addon cross-compiles and emits ArkTS declarations",
  { skip: process.env.ZIG_NAPI_TEST_OHOS !== "1" },
  (t) => {
    const { project, generate } = scaffold(t, "--zig-napi", checkout);
    generate();
    assert.ok(fs.existsSync(path.join(project, ".github/workflows/CI.yml")));
    // Remove the seed declaration to verify that the Zig generator produced it.
    fs.unlinkSync(path.join(project, "package/types/Index.d.ts"));
    execFileSync("zig", ["build", "--prefix", "package/libs"], { cwd: project, stdio: "inherit" });
    for (const [abi, machine] of [
      ["arm64-v8a", 183],
      ["armeabi-v7a", 40],
      ["x86_64", 62],
    ]) {
      const elf = fs.readFileSync(path.join(project, "package/libs", abi, "libdemo_native.so"));
      assert.equal(elf.subarray(0, 4).toString("hex"), "7f454c46", abi);
      assert.equal(elf.readUInt16LE(18), machine, abi);
    }
    assert.match(
      fs.readFileSync(path.join(project, "package/types/Index.d.ts"), "utf8"),
      /function add\(left: number, right: number\): number/,
    );
  },
);
