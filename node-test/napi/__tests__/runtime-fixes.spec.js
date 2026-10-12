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

nativeOnlyTest("repeated class definition failures release their cleanup context", (t) => {
  const result = isolated(`
    const baseline = [b.activeBytes(), b.activeAllocations()];
    for (let index = 0; index < 100; index += 1) {
      try { b.defineDuplicateClass(); throw new Error("class definition succeeded"); }
      catch (error) { if (!(error instanceof TypeError) || !/Duplicate class property name/.test(error.message)) throw error; }
    }
    console.log(JSON.stringify({ baseline, after: [b.activeBytes(), b.activeAllocations()] }));
  `, "classes");
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout.trim());
  t.deepEqual(output.after, output.baseline);
});

nativeOnlyTest("repeated static constant conversion failures release their class cleanup context", (t) => {
  const result = isolated(`
    const baseline = [b.activeBytes(), b.activeAllocations()];
    for (let index = 0; index < 100; index += 1) {
      try { b.defineFailingStaticClass(); throw new Error("class definition succeeded"); }
      catch (error) { if (!(error instanceof Error) || !/OutOfMemory/.test(error.message)) throw error; }
    }
    console.log(JSON.stringify({ baseline, after: [b.activeBytes(), b.activeAllocations()] }));
  `, "classes");
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout.trim());
  t.deepEqual(output.after, output.baseline);
});

nativeOnlyTest("module initialization errors fail addon loading", (t) => {
  const error = t.throws(() => loadAddon("init_failure"));
  t.regex(error.message, /InitFailed/);
});

nativeOnlyTest("module initialization preserves an existing JavaScript exception", (t) => {
  const error = t.throws(() => loadAddon("init_pending_exception"));
  t.regex(error.message, /original init exception/);
  t.notRegex(error.message, /InitFailed/);
});

nativeOnlyTest("bare export conversion errors fail addon loading", (t) => {
  const error = t.throws(() => loadAddon("export_failure"));
  t.regex(error.message, /OutOfMemory/);
});

test("Iterator.close calls own and inherited return methods and allows their absence", (t) => {
  const calls = [];
  const prototype = { return() { calls.push(this.marker); return { done: true }; } };
  for (const inherited of [false, true]) {
    const iterator = inherited ? Object.create(prototype) : { return: prototype.return };
    iterator.next = () => ({ done: true });
    iterator.marker = inherited ? "inherited" : "own";
    t.is(bindings.closeIterator(iterator), undefined);
  }
  t.deepEqual(calls, ["own", "inherited"]);
  t.is(bindings.closeIterator({ next: () => ({ done: true }) }), undefined);
});

test("AsyncIterator.close calls own and inherited return methods and allows their absence", async (t) => {
  const calls = [];
  const prototype = { return() { calls.push(this.marker); return Promise.resolve({ done: true, value: 7 }); } };
  for (const inherited of [false, true]) {
    const iterator = inherited ? Object.create(prototype) : { return: prototype.return };
    iterator.next = async () => ({ done: true });
    iterator.marker = inherited ? "inherited" : "own";
    t.deepEqual(await bindings.closeAsyncIterator(iterator), { done: true, value: 7 });
  }
  t.deepEqual(calls, ["own", "inherited"]);
  const result = await bindings.closeAsyncIterator({ next: async () => ({ done: true }) });
  t.true(result.done);
});

test("exported functions use their public metadata names", (t) => {
  t.is(bindings.add.name, "add");
  t.is(bindings.publicFunction.name, "publicFunction");
});

test("64 bit Number inputs preserve the validated integer value", (t) => {
  t.is(bindings.unsignedAsBigInt(2 ** 63), 2n ** 63n);
  t.is(bindings.unsignedAsBigInt(2 ** 64 - 2048), 2n ** 64n - 2048n);
  t.throws(() => bindings.unsignedAsBigInt(2 ** 64), { name: "RangeError" });
  t.is(bindings.signedAsBigInt(-(2 ** 63)), -(2n ** 63n));
  t.is(bindings.signedAsBigInt(2 ** 63 - 1024), 2n ** 63n - 1024n);
});

test("BigInt creation accepts the minimum signed 128 bit integer", (t) => {
  t.is(bindings.minSignedBigInt(), -(2n ** 127n));
});

test("ordinary arrays and typed arrays reject fractional integer inputs alike", (t) => {
  for (const input of [[1.5, 2.5], new Float64Array([1.5, 2.5]), new Float32Array([1.5, 2.5])]) {
    const error = t.throws(() => bindings.sumIntegerSlice(input), { name: "TypeError" });
    t.is(error.message, "Expected an integer for i32, got 1.5");
  }
  t.is(bindings.sumIntegerSlice([1, 2]), 3);
  t.is(bindings.sumIntegerSlice(new Float64Array([1, 2])), 3);
});

test("pagination objects retain items and total in both conversion directions", (t) => {
  t.deepEqual(bindings.page(), { items: [1, 2, 3], total: 10 });
  t.deepEqual(bindings.roundtripPage({ items: [4, 5], total: 20 }), { items: [4, 5], total: 20 });
  t.deepEqual(bindings.roundtripPage({ items: [], total: 0 }), { items: [], total: 0 });
  t.deepEqual(bindings.roundtripArrayList([1, 2, 3]), [1, 2, 3]);
  t.deepEqual(bindings.roundtripArrayList(new Uint32Array([4, 5])), [4, 5]);
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
