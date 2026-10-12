const test = require("ava");
const path = require("path");
const { spawnSync } = require("child_process");
const loadAddon = require("../../load-addon");
const bindings = loadAddon("conversion");
const isWasi = process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";
const nativeOnlyTest = isWasi ? test.skip : test;

async function within(promise, ms = 2000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Promise settlement timed out")), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function isolated(script, addon = "conversion") {
  const loaderPath = path.join(__dirname, "..", "..", "load-addon.js");
  return spawnSync(process.execPath, ["-e", `const b = require(${JSON.stringify(loaderPath)})(${JSON.stringify(addon)}); ${script}`], {
    encoding: "utf8",
    timeout: 4000,
  });
}

nativeOnlyTest("CallAsync rejects when its TSFN is aborted before dispatch", async (t) => {
  const error = await t.throwsAsync(within(bindings.tsfnCallAsyncThenAbort(() => t.fail("aborted callback ran"))));
  t.regex(error.message, /ThreadSafeFunction closed/);
});

nativeOnlyTest("TSFN finalization rejects every pending CallAsync completion", async (t) => {
  const promises = bindings.tsfnCallAsyncBatchThenAbort(() => t.fail("aborted callback ran"));
  const results = await within(Promise.all(promises.map((promise) => promise.then(
    () => ({ resolved: true }),
    (error) => ({ error }),
  ))));
  for (const result of results) t.regex(result.error.message, /ThreadSafeFunction closed/);
});

nativeOnlyTest("a synchronous CallAsync enqueue failure detaches only its completion", async (t) => {
  const delivered = [];
  const [accepted, rejected] = bindings.tsfnCallAsyncQueueFailure((value) => delivered.push(value));
  const error = await t.throwsAsync(within(rejected));
  t.notRegex(error.message, /already.*settled/i);
  t.is(await within(accepted), undefined);
  t.deepEqual(delivered, [1]);
});

nativeOnlyTest("a full bounded Blocking TSFN call on the JS thread reports WouldDeadlock", (t) => {
  const result = isolated(`
    const errors = [];
    for (const invoke of [b.tsfnBlockingQueueProbe, b.tsfnBuilderBlockingQueueProbe]) {
      try { invoke(() => {}); throw new Error("full queue accepted a call"); }
      catch (error) { errors.push({ code: error.code, message: error.message }); }
    }
    console.log(JSON.stringify(errors));
  `);
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  t.deepEqual(JSON.parse(result.stdout.trim()), [
    { code: "WouldDeadlock", message: "ThreadSafeFunction queue cannot accept this call" },
    { code: "WouldDeadlock", message: "ThreadSafeFunction queue cannot accept this call" },
  ]);
});
