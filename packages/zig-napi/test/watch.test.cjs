const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");
const { test } = require("node:test");

const cli = path.resolve(__dirname, "../bin/zig-napi.js");

for (const [signal, exitCode, firstFailure] of [
  ["SIGTERM", 143, false],
  ["SIGINT", 130, false],
  ["SIGTERM", 143, true],
]) {
  test(
    `watch forwards ${signal} to an active Zig build and stops queued builds${firstFailure ? " after a failed build" : ""}`,
    { timeout: 15_000 },
    async () => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), "zig-napi-watch-"));
      const project = path.join(directory, "project");
      const bin = path.join(directory, "bin");
      const log = path.join(directory, "zig.log");
      fs.mkdirSync(project);
      fs.mkdirSync(bin);
      fs.writeFileSync(
        path.join(project, "package.json"),
        JSON.stringify({
          name: "watch-fixture",
          napi: { binaryName: "addon", targets: ["aarch64-apple-darwin"] },
        }),
      );
      const source = path.join(project, "build.zig");
      fs.writeFileSync(source, "// before\n");
      fs.writeFileSync(
        path.join(bin, "zig"),
        `#!${process.execPath}
const fs = require("node:fs");
const log = ${JSON.stringify(log)};
if (${firstFailure} && !fs.existsSync(log)) {
  fs.appendFileSync(log, "START " + process.pid + "\\n");
  process.exit(1);
}
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => {
  fs.appendFileSync(log, "STOP " + signal + " " + process.pid + "\\n");
  process.exit(0);
});
fs.appendFileSync(log, "START " + process.pid + "\\n");
setInterval(() => {}, 1000);
`,
        { mode: 0o755 },
      );
      const watcher = spawn(
        process.execPath,
        [cli, "build", "--watch", "--cwd", project],
        {
          cwd: project,
          env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let logs = "";
      watcher.stdout.on("data", (data) => (logs += data));
      watcher.stderr.on("data", (data) => (logs += data));
      const closed = new Promise((resolve, reject) => {
        watcher.once("error", reject);
        watcher.once("close", (code, signal) => resolve({ code, signal }));
      });
      const running = (pid) => {
        try {
          process.kill(pid, 0);
          return true;
        } catch (error) {
          if (error.code === "ESRCH") return false;
          throw error;
        }
      };
      const waitUntil = async (predicate) => {
        const deadline = Date.now() + 4000;
        while (!predicate()) {
          assert.ok(Date.now() < deadline, "watch did not reach expected state: " + logs);
          await delay(25);
        }
      };
      let pid;
      try {
        await waitUntil(() => fs.existsSync(log));
        if (firstFailure) {
          await waitUntil(() => logs.includes("Watching Zig sources"));
          fs.writeFileSync(source, "// retry after the failed build\n");
          await waitUntil(() => fs.readFileSync(log, "utf8").match(/^START /gm).length === 2);
        }
        pid = Number([...fs.readFileSync(log, "utf8").matchAll(/^START (\d+)/gm)].at(-1)[1]);
        fs.writeFileSync(source, "// queue a rebuild during the active build\n");
        await delay(250);
        watcher.kill(signal);
        const result = await Promise.race([closed, delay(2000, null, { ref: false })]);
        assert.notEqual(
          result,
          null,
          "CLI must stop before the long-running Zig build finishes: " + logs,
        );
        assert.deepEqual(result, { code: exitCode, signal: null });
        await waitUntil(() => !running(pid));
        await delay(200);
        const events = fs.readFileSync(log, "utf8");
        assert.match(events, new RegExp(`STOP ${signal} ${pid}`));
        assert.equal(
          events.match(/^START /gm).length,
          firstFailure ? 2 : 1,
          "stopping must discard queued builds",
        );
      } finally {
        if (fs.existsSync(log)) {
          for (const [, started] of fs.readFileSync(log, "utf8").matchAll(/^START (\d+)/gm)) {
            if (running(Number(started))) process.kill(Number(started), "SIGKILL");
          }
        }
        if (watcher.exitCode === null && watcher.signalCode === null) watcher.kill("SIGKILL");
        await closed;
        fs.rmSync(directory, { recursive: true, force: true });
      }
    },
  );
}
