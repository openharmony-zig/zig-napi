const test = require("ava");
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
