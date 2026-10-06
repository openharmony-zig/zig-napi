const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const stageLoader = require("./loader-fixture.cjs");

for (const flavor of ["wasi", "wasip1"]) {
  test(`WASI ${flavor} string codecs preserve explicit lengths and owned copying fallbacks`, () => {
    const root = path.resolve(
      process.env.ZIG_NAPI_WASM_ARTIFACT_ROOT || path.join(__dirname, ".."),
    );
    const fixture = stageLoader(root, "example", flavor);
    try {
      const script = `
        const assert = require('node:assert/strict');
        const addon = require(${JSON.stringify(fixture.loader)});
        (async () => {
          try {
            for (const value of ['', '\\0éÿ', 'A\\0éÿ', 'é'.repeat(10000)]) {
              assert.equal(addon.parityLatin1(value), value);
              const external = addon.parityExternalLatin1(value);
              assert.equal(external.value, value);
              assert.equal(external.copied, true);
            }
            for (const value of ['', 'A😀\\0é', '😀'.repeat(10000)]) {
              const external = addon.parityExternalUtf16(value);
              assert.equal(external.value, value);
              assert.equal(external.copied, true);
            }
            assert.deepEqual(addon.parityStringLengths('A😀\\0é'), {utf8:8, utf16:5, latin1:5});
            console.log('STRING_CODECS_OK');
          } finally { await addon[Symbol.for('napi.rs.wasi.dispose')](); }
        })().catch(error => {console.error(error); process.exitCode = 1;});
      `;
      const result = spawnSync(process.execPath, ["-e", script], {
        encoding: "utf8",
        timeout: require("../test-timeout")(30000),
      });
      assert.equal(result.error, undefined, result.error?.message);
      assert.equal(result.signal, null, result.stderr);
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, /STRING_CODECS_OK/);
    } finally {
      fixture.cleanup();
    }
  });
}
