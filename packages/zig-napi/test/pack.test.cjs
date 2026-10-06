const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
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
  async () => {
    const hostTarget =
      process.platform === "darwin"
        ? `${process.arch === "arm64" ? "aarch64" : "x86_64"}-apple-darwin`
        : process.platform === "linux"
          ? `${process.arch === "arm64" ? "aarch64" : "x86_64"}-unknown-linux-gnu`
          : "x86_64-pc-windows-msvc";
    const hostAbi = `${process.platform}-${process.arch}${process.platform === "linux" ? "-gnu" : process.platform === "win32" ? "-msvc" : ""}`;
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
          `${hostTarget},wasm32-wasip1-threads`,
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
      // Real ESM imports use the native platform loader and expose provenance.
      run(process.execPath, [cli, "build", "--cwd", project, "--esm"], tooling);
      run(
        process.execPath,
        [
          "--input-type=module",
          "-e",
          "import {add,__napiBindingTarget} from './index.mjs';if(add(2,3)!==5||__napiBindingTarget!=='native')process.exit(1)",
        ],
        project,
      );
      run(process.execPath, [cli, "create-npm-dirs", "--cwd", project], tooling);
      const metadata = JSON.parse(fs.readFileSync(path.join(project, "package.json")));
      metadata.version = "2.3.4";
      fs.writeFileSync(path.join(project, "package.json"), JSON.stringify(metadata, null, 2));
      run(process.execPath, [cli, "version", "--cwd", project], tooling);
      const tPlatform = path.join(project, "npm", hostAbi, "package.json");
      assert.equal(JSON.parse(fs.readFileSync(tPlatform)).version, "2.3.4");
      const renameArgs = [
        cli,
        "rename",
        "--cwd",
        project,
        "--binary-name",
        "renamed_addon",
        "--package-name",
        "renamed-package",
      ];
      const before = fs.readFileSync(path.join(project, "package.json"), "utf8");
      assert.match(run(process.execPath, [...renameArgs, "--dry-run"], tooling), /renamed_addon/);
      assert.equal(fs.readFileSync(path.join(project, "package.json"), "utf8"), before);
      run(process.execPath, renameArgs, tooling);
      assert.equal(JSON.parse(fs.readFileSync(tPlatform)).name, "renamed-package-" + hostAbi);
      assert(!fs.existsSync(path.join(project, "test_addon.wasi.cjs")));
      run(
        process.execPath,
        ["-e", "const a=require('./renamed_addon.wasi.cjs');if(a.add(2,3)!==5)process.exit(1)"],
        project,
      );
      run(
        process.execPath,
        [
          "--input-type=module",
          "-e",
          "import {add} from './index.mjs';if(add(2,3)!==5)process.exit(1)",
        ],
        project,
      );
      run(process.execPath, [cli, "build", "--cwd", project, "--commonjs"], tooling);
      run(
        process.execPath,
        [
          "-e",
          "const a=require('.');if(a.add(2,3)!==5||a.__napiBindingTarget!=='native')process.exit(1)",
        ],
        project,
      );
      // Separate output directories must contain the actual wasm and native
      // artifacts, not just loaders pointing at nonexistent relative files.
      run(
        process.execPath,
        [
          cli,
          "build",
          "--cwd",
          project,
          "--target",
          "wasm32-wasip1-threads",
          "--build-output-dir",
          "dist with spaces",
        ],
        tooling,
      );
      run(
        process.execPath,
        [
          "-e",
          "const a=require('./dist with spaces/renamed_addon.wasi.cjs');if(a.add(2,3)!==5)process.exit(1)",
        ],
        project,
      );
      if (process.platform === "darwin") {
        const pkg = JSON.parse(fs.readFileSync(path.join(project, "package.json")));
        pkg.napi.targets.push("universal-apple-darwin");
        fs.writeFileSync(path.join(project, "package.json"), JSON.stringify(pkg, null, 2));
        run(
          process.execPath,
          [cli, "build", "--cwd", project, "--target", "x86_64-macos"],
          tooling,
        );
        run(process.execPath, [cli, "universalize", "--cwd", project], tooling);
        const universal = path.join(project, "renamed_addon.darwin-universal.node");
        const architectures = run("lipo", ["-archs", universal], project);
        assert.match(architectures, /x86_64/);
        assert.match(architectures, /arm64/);
        run(
          process.execPath,
          ["-e", `const a=require(${JSON.stringify(universal)});if(a.add(2,3)!==5)process.exit(1)`],
          project,
        );
      }
      // The platform loader prefers a universal artifact when present. Remove
      // this completed test's artifact so watch observes the rebuilt host file.
      const fat = path.join(project, "renamed_addon.darwin-universal.node");
      if (fs.existsSync(fat)) fs.unlinkSync(fat);
      run(
        process.execPath,
        [cli, "build", "--cwd", project, "--target", "x86_64-linux-gnu"],
        tooling,
      );
      const elf = path.join(project, "renamed_addon.linux-x64-gnu.node");
      const signer = require(path.join(installed, "bin", "ohos-selfsign.cjs"));
      const unsigned = fs.readFileSync(elf);
      signer.signFileAtomic(elf, true);
      const signed = fs.readFileSync(elf);
      assert(signer.checkSelfsign(signed).ok, "ELF self-signature verifies");
      signer.signFileAtomic(elf, true);
      assert(fs.readFileSync(elf).equals(signed), "forced signing is reproducible");
      const corrupt = Buffer.from(signed);
      corrupt[4096] ^= 1;
      assert(!signer.checkSelfsign(corrupt).ok, "tampering is detected");
      assert.throws(() => signer.signFileAtomic(elf), /already has/);
      assert(fs.readFileSync(elf).equals(signed), "failure leaves the artifact intact");
      assert(unsigned.length < signed.length);
      const sourcePathZig = path.join(project, "src", "lib.zig");
      const sourceBefore = fs.readFileSync(sourcePathZig, "utf8");
      const watcher = spawn(
        process.execPath,
        [cli, "build", "--cwd", project, "--watch", "--commonjs"],
        { cwd: tooling, stdio: ["ignore", "pipe", "pipe"] },
      );
      let logs = "";
      watcher.stdout.on("data", (data) => (logs += data));
      watcher.stderr.on("data", (data) => (logs += data));
      const waitUntil = async (predicate) => {
        const deadline = Date.now() + 90000;
        while (!predicate()) {
          if (Date.now() > deadline || watcher.exitCode !== null)
            throw new Error("watch failed: " + logs);
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
      };
      try {
        await waitUntil(() => logs.includes("Watching Zig sources"));
        const binary = path.join(project, `renamed_addon.${hostAbi}.node`);
        const modified = fs.statSync(binary).mtimeMs;
        const changed = sourceBefore.replace("return left + right;", "return left + right + 1;");
        assert.notEqual(changed, sourceBefore, "modify the scaffold's real implementation");
        fs.writeFileSync(sourcePathZig, changed);
        await waitUntil(() => fs.statSync(binary).mtimeMs > modified);
        run(
          process.execPath,
          ["-e", "const a=require('.');if(a.add(2,3)!==6)process.exit(1)"],
          project,
        );
      } finally {
        watcher.kill("SIGTERM");
        await new Promise((resolve) => watcher.once("close", resolve));
      }
    } finally {
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  },
);
