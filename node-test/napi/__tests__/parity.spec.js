const test = require("ava");
const loadAddon = require("../../load-addon");
const native = loadAddon("example");

test("string codecs count bytes/code units and preserve Latin1 and NUL", (t) => {
  t.deepEqual(native.parityStringLengths("A😀\0é"), { utf8: 8, utf16: 5, latin1: 5 });
  t.is(native.parityLatin1("\0éÿ"), "\0éÿ");
  t.deepEqual(native.parityStringLengths(""), { utf8: 0, utf16: 0, latin1: 0 });
});

test("converted objects create own properties without invoking inherited setters", (t) => {
  let calls = 0;
  Object.defineProperty(Object.prototype, "x", {
    configurable: true,
    set() {
      calls++;
    },
  });
  let value;
  try {
    value = native.parityObject();
  } finally {
    delete Object.prototype.x;
  }
  t.is(calls, 0);
  t.is(value.x, 42);
  t.true(Object.prototype.hasOwnProperty.call(value, "__proto__"));
  t.is(value.__proto__, 7);
  t.is(Object.getPrototypeOf(value), Object.prototype);
  t.deepEqual(Object.getOwnPropertyDescriptor(value, "x"), {
    value: 42,
    enumerable: true,
    writable: true,
    configurable: true,
  });
});

test("function receiver, binding, constructor and closure state", (t) => {
  function add(value) {
    return this.base + value;
  }
  t.is(native.parityApply(add, { base: 40 }, 2), 42);
  t.is(native.parityBind(add, { base: 10 })(3), 13);
  function Box(value) {
    this.value = value;
  }
  const box = native.parityConstruct(Box, 42);
  t.true(box instanceof Box);
  t.is(box.value, 42);
  t.is(native.parityTools.functionName(add), "add");
  const first = native.parityClosure(10);
  const second = native.parityClosure(100);
  t.is(first(2), 12);
  t.is(first(3), 15);
  t.is(second(1), 101);
  t.throws(() => first("invalid"), { instanceOf: TypeError });
  t.is(first(1), 16);
});

test("callback and script failures retain the original exception", (t) => {
  const reason = { sentinel: true };
  let caught;
  try {
    native.parityApply(
      () => {
        throw reason;
      },
      {},
      1,
    );
  } catch (err) {
    caught = err;
  }
  t.is(caught, reason);
  t.is(native.parityScript("6 * 7"), 42);
  t.throws(() => native.parityScript("throw new Error('script failed')"), {
    message: "script failed",
  });
  t.is(native.parityScope(), "escaped");
});

test("typed Promise consumption chains fulfillment, rejection and finally", async (t) => {
  t.is(await native.parityPromise(Promise.resolve(21), (value) => value * 2), 42);
  const reason = { sentinel: 42 };
  let received;
  t.is(
    await native.parityPromiseCatch(Promise.reject(reason), (value) => {
      received = value;
      return 7;
    }),
    7,
  );
  t.is(received, reason);
  let final = 0;
  t.is(
    await native.parityPromiseFinally(Promise.resolve(12), () => {
      final++;
    }),
    12,
  );
  t.is(final, 1);
  t.throws(() => native.parityPromise({}, () => 1), { instanceOf: TypeError });
  let rejected;
  try {
    await native.parityPromise(Promise.resolve(1), () => {
      throw reason;
    });
  } catch (err) {
    rejected = err;
  }
  t.is(rejected, reason);
});

test("native maps, sets and recursive JSON validate and release conversions", (t) => {
  const object = Object.create({ inherited: "omit" });
  Object.defineProperty(object, "__proto__", { value: "safe", enumerable: true });
  object.a = "one";
  t.deepEqual(Object.keys(native.parityMap(object)).sort(), ["__proto__", "a"]);
  t.is(native.parityMap(object).__proto__, "safe");
  t.throws(() => native.parityMap({ a: 1 }), { instanceOf: TypeError });
  t.deepEqual([...native.paritySet(new Set([1, 2, 1]))], [1, 2]);
  t.throws(
    () =>
      native.paritySet({
        values() {
          return [1][Symbol.iterator]();
        },
      }),
    { instanceOf: TypeError },
  );
  const json = { string: "A😀\0", null: null, bool: true, number: 1.5, array: [1, { x: 2 }] };
  t.deepEqual(native.parityJson(json), json);
  const cyclic = {};
  cyclic.self = cyclic;
  t.throws(() => native.parityJson(cyclic), { instanceOf: TypeError, message: /cyclic/ });
  t.throws(() => native.parityJson({ missing: undefined }), { instanceOf: TypeError });
  t.throws(() => native.parityJson(Infinity), { instanceOf: TypeError });
  const reason = new Error("getter");
  t.throws(
    () =>
      native.parityJson({
        get x() {
          throw reason;
        },
      }),
    { is: reason },
  );
  for (let i = 0; i < 500; i++) t.deepEqual(native.parityJson(json), json);
});

test("native and JS iterators consume the protocol including done and errors", async (t) => {
  t.deepEqual([...native.parityIterator(3)], [0, 1, 2]);
  t.is(native.parityIteratorSum([1, 2, 3][Symbol.iterator]()), 6);
  t.is(
    native.parityIteratorSum({
      next() {
        return { done: true };
      },
    }),
    0,
  );
  const reason = new Error("iterator failed");
  t.throws(
    () =>
      native.parityIteratorSum({
        next() {
          throw reason;
        },
      }),
    { is: reason },
  );
  async function* generate() {
    yield 7;
  }
  const iterator = generate();
  t.deepEqual(await native.parityAsyncIteratorNext(iterator), { done: false, value: 7 });
  t.deepEqual(await native.parityAsyncIteratorNext(iterator), { done: true, value: undefined });
});

test("typed TSFN results settle, adopt returned Promises and preserve thrown values", async (t) => {
  t.is(await native.parityTsfnAsync((value) => value * 2, 21), 42);
  await t.throwsAsync(
    native.parityTsfnAsync(() => "wrong", 1),
    { instanceOf: TypeError },
  );
  const reason = { primitiveOrObject: true };
  let rejected;
  try {
    await native.parityTsfnAsync(() => {
      throw reason;
    }, 1);
  } catch (err) {
    rejected = err;
  }
  t.is(rejected, reason);
  t.is(await native.parityTsfnPromise((value) => Promise.resolve(value * 2), 21), 42);
  try {
    await native.parityTsfnPromise(() => Promise.reject(reason), 1);
  } catch (err) {
    rejected = err;
  }
  t.is(rejected, reason);
});

test("class instance parameters validate native identity before reading payloads", (t) => {
  const factory = native.ParityFactory.create(42);
  t.is(native.parityFactoryInstance(factory), 42);
  t.throws(() => native.parityFactoryInstance(Object.create(native.ParityFactory.prototype)), {
    instanceOf: TypeError,
  });
  const instance = new native.ParityCounter(10);
  t.is(native.parityClassInstance(instance, 2), 12);
  t.is(instance.value, 12);
  t.throws(() => native.parityClassInstance({}, 1), { instanceOf: TypeError });
  t.throws(() => native.parityClassInstance(Object.create(native.ParityCounter.prototype), 1), {
    instanceOf: TypeError,
  });
});

test("metadata renames and hides members, enforces readonly and combines accessors", (t) => {
  const value = new native.MetadataCounter(10);
  t.is(value.count, 10);
  t.false("value" in value);
  t.false("secret" in value);
  t.false("napi_config" in native.MetadataCounter);
  t.false("MetadataSchema" in native.parityTools);
  t.is(value.add(2), 12);
  t.is(value.double, 24);
  value.double = 40;
  t.is(value.count, 20);
  t.false(Reflect.set(value, "count", 99));
  t.is(value.count, 20);
  t.is(
    Object.getOwnPropertyDescriptor(native.MetadataCounter.prototype, "double").get instanceof
      Function,
    true,
  );
  t.is(
    Object.getOwnPropertyDescriptor(native.MetadataCounter.prototype, "double").set instanceof
      Function,
    true,
  );
  t.is(native.parityShared(value), value);
  for (let i = 0; i < 1000; i++) t.is(native.parityShared(value), value);
});

test("Date, Symbol and callback receivers retain their typed semantics", (t) => {
  t.is(native.parityDate(new Date(123456)).getTime(), 123456);
  t.true(Number.isNaN(native.parityDate(new Date(NaN)).getTime()));
  t.throws(() => native.parityDate({ getTime: () => 1 }), { instanceOf: TypeError });
  const symbol = Symbol("same");
  const result = native.paritySymbol(symbol);
  t.is(result.input, symbol);
  t.is(typeof result.unique, "symbol");
  t.not(result.unique, native.paritySymbol(symbol).unique);
  t.throws(() => native.paritySymbol("symbol"), { instanceOf: TypeError });
  t.is(native.parityThis.call({ base: 40 }, 2), 42);
  t.throws(() => native.parityThis.call({ base: "wrong" }, 2), { instanceOf: TypeError });
});

test("native async generators produce asynchronously and retain independent state", async (t) => {
  const first = native.parityAsyncGenerator(3);
  const second = native.parityAsyncGenerator(1);
  t.is(first[Symbol.asyncIterator](), first);
  const results = await Promise.all([first.next(), first.next(), second.next()]);
  t.deepEqual(
    results.map((value) => value.value),
    [0, 1, 0],
  );
  t.deepEqual(await first.next(), { done: false, value: 2 });
  t.true((await first.next()).done);
  t.true((await second.next()).done);
});

test("object metadata and discriminated unions retain shape and rollback invalid inputs", (t) => {
  const value = native.parityMetadataObject({ count: 42, missing: null, internal: "ignore" });
  t.deepEqual(value, { count: 42, missing: null });
  t.false(Reflect.set(value, "count", 1));
  for (const kind of ["first", "second"])
    t.deepEqual(native.parityTagged({ kind, data: { count: 7 } }), { kind, data: { count: 7 } });
  t.deepEqual(native.parityTagged({ kind: "text", data: "A😀\0" }), {
    kind: "text",
    data: "A😀\0",
  });
  t.throws(() => native.parityTagged({ kind: "unknown", data: 1 }), { instanceOf: TypeError });
  const reason = new Error("discriminant getter");
  t.throws(
    () =>
      native.parityTagged({
        get kind() {
          throw reason;
        },
      }),
    { is: reason },
  );
  for (let i = 0; i < 500; i++) {
    t.throws(() => native.parityMetadataObject({ count: 42, missing: "bad" }), {
      instanceOf: TypeError,
    });
    t.throws(() => native.parityTagged({ kind: "first", data: { count: "bad" } }), {
      instanceOf: TypeError,
    });
  }
});

test("TSFN builders configure weak queues and expose queue-full rejection", async (t) => {
  const keepAlive = setInterval(() => {}, 20);
  t.teardown(() => clearInterval(keepAlive));
  const promises = native.parityTsfnBuilder((value) => value * 2);
  const rejected = t.throwsAsync(promises.second, { code: "QueueFull" });
  t.is(await promises.first, 42);
  await rejected;
});

(process.env.NAPI_RS_FORCE_WASI ? test.skip : test)(
  "bounded TSFN blocking producers resume on drain and abort",
  async (t) => {
    const values = [];
    await new Promise((resolve) => {
      native.parityTsfnBlocking((value) => {
        values.push(value);
        if (values.length === 3) resolve();
      });
    });
    t.deepEqual(values, [1, 2, 3]);
    t.true(native.parityTsfnAbort(() => {}));
  },
);

test("iterator return and throw close native producer state", async (t) => {
  const iterator = native.parityIterator(100);
  t.is(iterator.next().value, 0);
  t.true(iterator.return().done);
  t.true(iterator.next().done);
  const reason = { sentinel: 42 };
  const thrown = native.parityIterator(100);
  try {
    thrown.throw(reason);
    t.fail("must throw");
  } catch (err) {
    t.is(err, reason);
  }
  t.true(thrown.next().done);
  const async = native.parityAsyncGenerator(100);
  t.is((await async.next()).value, 0);
  t.true((await async.return()).done);
  t.true((await async.next()).done);
  const rejected = native.parityAsyncGenerator(100);
  try {
    await rejected.throw(reason);
    t.fail("must reject");
  } catch (err) {
    t.is(err, reason);
  }
  t.true((await rejected.next()).done);
});

test("real Web Streams native pull, backpressure, reader and writer lifecycle", async (t) => {
  const stream = native.parityNativeReadable(3);
  t.true(stream instanceof ReadableStream);
  const reader = native.parityReadable(stream);
  t.true(stream.locked);
  for (let i = 0; i < 3; i++)
    t.deepEqual(await native.parityRead(reader), { value: i, done: false });
  t.true((await native.parityRead(reader)).done);
  native.parityReaderRelease(reader);
  t.false(stream.locked);
  const reason = { sentinel: true };
  let cancelled;
  const cancelledReader = native.parityReadable(
    new ReadableStream({
      cancel(r) {
        cancelled = r;
      },
    }),
  );
  await native.parityReaderCancel(cancelledReader, reason);
  t.is(cancelled, reason);
  native.parityReaderRelease(cancelledReader);
  const writes = [];
  let closed = 0;
  const output = new WritableStream({
    write(value) {
      writes.push(value);
    },
    close() {
      closed++;
    },
  });
  const writer = native.parityWritable(output);
  await native.parityWrite(writer, 42);
  await native.parityWriterClose(writer);
  native.parityWriterRelease(writer);
  t.deepEqual(writes, [42]);
  t.is(closed, 1);
  t.false(output.locked);
  let aborted;
  const abortWriter = native.parityWritable(
    new WritableStream({
      abort(value) {
        aborted = value;
      },
    }),
  );
  await native.parityWriterAbort(abortWriter, reason);
  native.parityWriterRelease(abortWriter);
  t.is(aborted, reason);
  t.throws(() => native.parityReadable({}), { instanceOf: TypeError });
  const rejectedReader = native.parityReadable(
    new ReadableStream({
      start(controller) {
        controller.error(reason);
      },
    }),
  );
  try {
    await native.parityRead(rejectedReader);
    t.fail("must reject");
  } catch (err) {
    t.is(err, reason);
  }
  native.parityReaderRelease(rejectedReader);
});

(process.env.NAPI_RS_FORCE_WASI ? test.skip : test)(
  "shared references clone and dispose from native threads",
  (t) => {
    for (let i = 0; i < 100; i++) {
      const object = { value: i };
      t.is(native.paritySharedThread(object), object);
    }
  },
);

test("environment instance data and removable cleanup hooks", (t) => {
  t.deepEqual(native.parityEnvironment(), {
    stored: true,
    replacement_rejected: true,
    async_removed: true,
  });
  t.deepEqual(native.parityEnvironment(), {
    stored: true,
    replacement_rejected: true,
    async_removed: true,
  });
});
test("external Latin1 and UTF16 strings transfer owned storage", (t) => {
  for (const input of ["", "A\0éÿ", "é".repeat(10000)])
    t.is(native.parityExternalLatin1(input).value, input);
  for (const input of ["", "A😀\0é", "😀".repeat(10000)])
    t.is(native.parityExternalUtf16(input).value, input);
});

test("namespace class exports and typed instances use their public names", (t) => {
  const instance = new native.parityTools.RenamedCounter(42);
  t.is(native.parityNamespaced(instance), 42);
  t.is(native.parityTools.RenamedCounter.name, "RenamedCounter");
  t.is(native.NamespacedCounter, undefined);
});

test("native collection and JSON captures deep clone for async tasks", async (t) => {
  const map = { key: "hello😀" };
  const mapTask = native.parityAsyncMap(map);
  map.key = "changed";
  t.deepEqual(await mapTask, { key: "hello😀" });
  const json = { array: [1, { key: "initial" }], __proto__: null };
  const jsonTask = native.parityAsyncJson(json);
  json.array[1].key = "changed";
  t.deepEqual(await jsonTask, { array: [1, { key: "initial" }] });
});

test("weak references collect their target and survive environment termination", (t) => {
  const { spawnSync } = require("node:child_process");
  const loader = require.resolve("../../load-addon");
  const result = spawnSync(
    process.execPath,
    [
      "--expose-gc",
      "-e",
      `
    const assert = require('node:assert/strict');
    const addon = require(${JSON.stringify(loader)})('example');
    const {Worker} = require('node:worker_threads');
    (async () => {
      const weak = addon.parityWeakClosure({ sentinel: true });
      for (let i=0;i<20;i++) { await new Promise(r=>setImmediate(r)); global.gc(); }
      assert.equal(weak(), undefined, 'weak reference must not root its target');
      for (let i=0;i<5;i++) {
        const worker = new Worker(\`const {parentPort,workerData}=require('node:worker_threads'); const a=require(workerData)('example'); global.saved=a.parityWeakClosure({});parentPort.postMessage('ready');\`, {eval:true,workerData:${JSON.stringify(loader)}});
        await new Promise((r,j)=>{worker.once('message',r);worker.once('error',j)});
        await worker.terminate();
      }
      console.log('WEAK_REFERENCE_CLEANUP_OK');
    })().catch(err=>{console.error(err);process.exitCode=1});
  `,
    ],
    { encoding: "utf8", timeout: require("../../test-timeout")(20000) },
  );
  t.is(result.error, undefined, result.error?.message);
  t.is(result.status, 0, result.stderr);
  t.true(result.stdout.includes("WEAK_REFERENCE_CLEANUP_OK"));
});

(process.env.NAPI_RS_FORCE_WASI ? test.skip : test)(
  "native workers await JS promise fulfillment and rejection without blocking the JS lane",
  async (t) => {
    t.is(await native.parityAwaitPromise(Promise.resolve(21)), 42);
    t.is(
      await native.parityAwaitPromise(new Promise((resolve) => setTimeout(() => resolve(12), 10))),
      24,
    );
    await t.throwsAsync(
      native.parityAwaitPromise(Promise.reject(new Error("promise-native-rejection"))),
      { code: "ERR_NAPI_PROMISE_REJECTED", message: "Error: promise-native-rejection" },
    );
    await t.throwsAsync(native.parityAwaitPromise(Promise.resolve("invalid")), {
      instanceOf: TypeError,
    });
  },
);

(process.env.NAPI_RS_FORCE_WASI ? test.skip : test)(
  "terminating an environment cancels a native promise waiter",
  (t) => {
    const { spawnSync } = require("node:child_process");
    const loader = require.resolve("../../load-addon");
    const result = spawnSync(
      process.execPath,
      [
        "-e",
        `
    const {Worker} = require('node:worker_threads');
    (async () => {
      for(let i=0;i<5;i++) {
        const worker = new Worker(\`const {parentPort,workerData}=require('node:worker_threads'); const addon=require(workerData)('example'); addon.parityAwaitPromise(new Promise(()=>{})).catch(()=>{});parentPort.postMessage('ready');\`, {eval:true,workerData:${JSON.stringify(loader)}});
        await new Promise((r,j)=>{worker.once('message',r);worker.once('error',j)});
        await worker.terminate();
      }
      console.log('PROMISE_WAITER_CLEANUP_OK');
    })().catch(e=>{console.error(e);process.exitCode=1});
  `,
      ],
      { encoding: "utf8", timeout: require("../../test-timeout")(20000) },
    );
    t.is(result.error, undefined, result.error?.message);
    t.is(result.status, 0, result.stderr);
    t.true(result.stdout.includes("PROMISE_WAITER_CLEANUP_OK"));
  },
);

test("global Symbol registry preserves identity", (t) => {
  t.is(native.paritySymbolFor("zig-napi.parity"), Symbol.for("zig-napi.parity"));
});
