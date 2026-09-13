const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    timeout: 180_000,
    shell: process.platform === "win32",
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, `${command}: ${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

test(
  "packed CLI scaffolds and builds using only its installed Zig sources",
  { timeout: 600_000 },
  () => {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-pack-"));
    try {
      const packageDir = path.resolve(__dirname, "..");
      const tooling = path.join(scratch, "tooling");
      fs.mkdirSync(tooling);
      run("npm", ["pack", "--pack-destination", scratch], packageDir);
      const archive = fs.readdirSync(scratch).find((name) => name.endsWith(".tgz"));
      assert.ok(archive);
      run(
        "npm",
        ["install", "--ignore-scripts", "--no-audit", "--no-fund", path.join(scratch, archive)],
        tooling,
      );
      const installed = path.join(tooling, "node_modules", "@ohos-rs", "zig-cli");
      const cli = path.join(installed, "bin", "zig-napi.js");
      const project = path.join(scratch, "addon with spaces");
      run(
        process.execPath,
        [
          cli,
          "new",
          project,
          "--no-interactive",
          "--name",
          "test-addon",
          "--addon",
          "test_addon",
          "--targets",
          "aarch64-apple-darwin,wasm32-wasip1-threads",
        ],
        tooling,
      );
      const zon = fs.readFileSync(path.join(project, "build.zig.zon"), "utf8");
      const sourcePath = zon.match(/\.path = "([^"]+)"/)[1];
      assert.equal(
        fs.realpathSync(path.resolve(project, sourcePath)),
        fs.realpathSync(path.join(installed, "zig")),
      );
      const generated = JSON.parse(fs.readFileSync(path.join(project, "package.json"), "utf8"));
      assert.equal(
        generated.devDependencies["@ohos-rs/zig-cli"],
        require("../package.json").version,
      );
      assert.equal(generated.devDependencies["zig-napi"], undefined);
      run(process.execPath, [cli, "build", "--cwd", project], tooling);
      const outputDir = path.join(project, "zig-out", "node");
      const addon = fs.readdirSync(outputDir).find((name) => name.endsWith(".node"));
      assert.ok(addon);
      const load = `const a=require(${JSON.stringify(path.join(outputDir, addon))});if(a.add(2,3)!==5)process.exit(1);`;
      run(process.execPath, ["-e", load], project);

      // Install the scaffold's real runtime dependencies outside the workspace.
      // The CLI has not been published yet, so resolve that dev dependency to
      // the package we just installed, retaining the generated-version check.
      generated.devDependencies["@ohos-rs/zig-cli"] = `file:${installed}`;
      fs.writeFileSync(path.join(project, "package.json"), JSON.stringify(generated, null, 2));
      run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], project);
      run(
        process.execPath,
        [cli, "build", "--cwd", project, "--target", "wasm32-wasip1-threads"],
        tooling,
      );
      const wasiLoad = `const a=require('./test_addon.wasi.cjs');if(a.add(2,3)!==5)process.exit(1);`;
      run(process.execPath, ["-e", wasiLoad], project);
    } finally {
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  },
);
