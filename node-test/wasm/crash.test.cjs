const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

test("a real WASI worker trap is quarantined and disposal rejects without hanging", () => {
  const root = path.resolve(process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT || path.join(__dirname, ".."));
  assert(
    fs.existsSync(path.join(root, "async_tasks.wasm32-wasi.wasm")),
    "build the threaded WASI artifacts first",
  );
  const fixture = require("./loader-fixture.cjs")(root, "async_tasks", "wasi");
  const script = `
    const assert = require('node:assert/strict');
    const addon = require(${JSON.stringify(fixture.loader)});
    let handled = false;
    const timeout = setTimeout(() => { console.error('crash disposal timed out'); process.exitCode = 1; }, ${require("../test-timeout")(10000)});
    process.on('uncaughtException', async error => {
      if (handled) return;
      handled = true;
      try {
        const first = addon[Symbol.for('napi.rs.wasi.dispose')]();
        const second = addon[Symbol.for('napi.rs.wasi.dispose')]();
        assert.equal(first, second, 'crash disposal must remain latched');
        await assert.rejects(first, failure => failure.code === 'ERR_NAPI_WASI_THREAD_CRASH' && failure.cause instanceof Error);
        console.log('CRASH_QUARANTINE_OK');
      } catch (failure) { console.error(failure); process.exitCode = 1; }
      finally { clearTimeout(timeout); }
    });
    addon.wasmTrapAsync().catch(() => {});
  `;
  let result;
  try {
    result = spawnSync(process.execPath, ["-e", script], {
      encoding: "utf8",
      timeout: require("../test-timeout")(20000),
    });
  } finally {
    fixture.cleanup();
  }
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null, result.stderr);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /CRASH_QUARANTINE_OK/);
});
