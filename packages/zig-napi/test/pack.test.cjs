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
      assert.deepEqual(fs.readdirSync(path.join(installed, "bin")), ["zig-napi.js"]);
      assert.ok(fs.existsSync(path.join(installed, "lib", "cli.cjs")));
      assert.ok(fs.existsSync(path.join(installed, "licenses", "NAPI-RS-LICENSE")));
      assert.doesNotMatch(run(process.execPath, [cli, "build", "--help"], tooling), /ohos-sign/);
      // Check every selectable platform's file identity against napi-rs using
      // Zig's resolved targets, without needing to execute foreign binaries.
      const allTargets = JSON.parse(
        run(
          process.execPath,
          [cli, "new", "planned", "--no-interactive", "--enable-all-targets", "--dry-run"],
          tooling,
        ),
      ).targets;
      const targetCheck = path.join(scratch, "target-check");
      fs.mkdirSync(targetCheck);
      fs.copyFileSync(
        path.join(installed, "zig/src/build/napi-build.zig"),
        path.join(targetCheck, "helper.zig"),
      );
      const { parseTriple } = require("@napi-rs/cli");
      const { zigTarget } = require("../lib/targets.cjs");
      const checks = allTargets
        .filter((target) => !target.startsWith("universal-"))
        .map((target) => {
          const wasm = target.startsWith("wasm32-");
          const triple = wasm ? "wasm32-wasi" : zigTarget(target);
          const features = target.endsWith("-threads")
            ? "query.cpu_features_add = std.Target.wasm.featureSet(&.{.atomics});"
            : "";
          return `{ var query = try std.Target.Query.parse(.{ .arch_os_abi = ${JSON.stringify(triple)} }); ${features} _ = &query; const label = napi.nodePlatformArchAbi(b, b.resolveTargetQuery(query)); if (!std.mem.eql(u8, label, ${JSON.stringify(parseTriple(target).platformArchABI)})) return error.PlatformMismatch; }`;
        });
      fs.writeFileSync(
        path.join(targetCheck, "build.zig"),
        `const std = @import("std"); const napi = @import("helper.zig"); pub fn build(b: *std.Build) !void { ${checks.join("\n")} }`,
      );
      run("zig", ["build"], targetCheck);
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
      const platformDirs = fs.readdirSync(path.join(project, "npm")).sort();
      assert.deepEqual(platformDirs, [hostAbi, "wasm32-wasi"].sort());
      for (const platform of platformDirs) {
        const manifest = JSON.parse(
          fs.readFileSync(path.join(project, "npm", platform, "package.json"), "utf8"),
        );
        assert.equal(manifest.name, `test-addon-${platform}`);
        assert.equal(manifest.version, "0.1.0");
        assert.equal(
          manifest.main,
          platform === "wasm32-wasi" ? "test_addon.wasi.cjs" : `test_addon.${hostAbi}.node`,
        );
      }
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
      run(process.execPath, [cli, "build", "--platform", "--cwd", project], tooling);
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
      // Exercise the generated build-and-test workflow with its declared runner.
      run("npm", ["test"], project);
      // Compiler options and relocated output must work with a real addon,
      // including a binding nested below its native artifact.
      run(
        process.execPath,
        [
          cli,
          "build",
          "--cwd",
          project,
          "--platform",
          "-t",
          hostTarget,
          "--target-dir",
          "other prefix",
          "-o",
          "native dist",
          "--js",
          "nested/loader.cjs",
          "--dts",
          "types/api.d.ts",
          "--dts-header",
          "// parity header\n",
          "--no-dts-cache",
          "--strip",
        ],
        tooling,
      );
      run(
        process.execPath,
        [
          "-e",
          "const a=require('./native dist/nested/loader.cjs');if(a.add(2,3)!==5)process.exit(1)",
        ],
        project,
      );
      assert.match(
        fs.readFileSync(path.join(project, "native dist/types/api.d.ts"), "utf8"),
        /^\/\/ parity header\n/,
      );
      run(
        process.execPath,
        [cli, "build", "--cwd", project, "--no-platform", "-o", "plain dist"],
        tooling,
      );
      run(
        process.execPath,
        ["-e", "const a=require('./plain dist/test_addon.node');if(a.add(2,3)!==5)process.exit(1)"],
        project,
      );
      run(
        process.execPath,
        [cli, "build", "--platform", "--cwd", project, "--target", "wasm32-wasip1-threads"],
        tooling,
      );
      const wasiLoad = `const a=require('./test_addon.wasi.cjs');if(a.add(2,3)!==5)process.exit(1);`;
      run(process.execPath, ["-e", wasiLoad], project);
      // Real ESM imports use the native platform loader and expose provenance.
      run(
        process.execPath,
        [cli, "build", "--platform", "--cwd", project, "--esm", "--js-binding", "index.mjs"],
        tooling,
      );
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
      run(process.execPath, [cli, "build", "--platform", "--cwd", project, "--commonjs"], tooling);
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
          [cli, "build", "--platform", "--cwd", project, "--target", "x86_64-macos"],
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
        [cli, "build", "--platform", "--cwd", project, "--target", "x86_64-linux-gnu"],
        tooling,
      );
      const elf = path.join(project, "renamed_addon.linux-x64-gnu.node");
      assert.equal(fs.readFileSync(elf).subarray(0, 4).toString("hex"), "7f454c46");
      const sourcePathZig = path.join(project, "src", "lib.zig");
      const sourceBefore = fs.readFileSync(sourcePathZig, "utf8");
      const watcher = spawn(
        process.execPath,
        [cli, "build", "--platform", "--cwd", project, "--watch", "--commonjs"],
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
