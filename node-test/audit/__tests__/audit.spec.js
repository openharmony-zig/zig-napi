const test = require("ava");
const path = require("path");
const { spawnSync } = require("child_process");
const loadPath = path.join(__dirname, "..", "..", "load-addon.js");
const a = require(loadPath)("audit");
const existing = require(loadPath)("example");

function child(body, flags = []) {
  const prelude = `const a=require(${JSON.stringify(loadPath)})("audit");`;
  const result = spawnSync(process.execPath, [...flags, "-e", prelude + body], {
    encoding: "utf8",
    timeout: 10000,
  });
  return result;
}

test("ordinary string and callback return types are checked", (t) => {
  t.throws(() => a.string(123));
  t.throws(() => a.string());
  t.throws(() => existing.call0(() => "oops"));
  t.is(a.string("ok"), "ok");
  t.is(
    existing.call0(() => 17),
    17,
  );
});

test("getter exceptions preserve the original JS exception", (t) => {
  const error = new Error("getter boom");
  t.is(
    t.throws(() =>
      existing.translatePoint(
        {
          get x() {
            throw error;
          },
          y: 2,
        },
        1,
        2,
      ),
    ),
    error,
  );
  t.deepEqual(existing.translatePoint({ x: 1, y: 2 }, 1, 2), { x: 2, y: 4 });
});

test("numeric bounds throw without terminating Node", (t) => {
  const result = child(
    `const assert=require('assert');assert.throws(()=>a.unsigned(-1));assert.throws(()=>a.smallSigned(128));assert.throws(()=>a.smallSigned(NaN));assert.throws(()=>a.smallSigned(Infinity));assert.strictEqual(a.smallSigned(127),127);assert.strictEqual(a.maxUnsigned(),Number(18446744073709551615n));`,
  );
  t.is(result.status, 0, result.stderr);
  t.is(result.signal, null);
});

test("fixed arrays, fixed strings and void callback signatures work", (t) => {
  t.is(a.fixed([2, 3]), 5);
  t.true(a.fixedString("ok"));
  let called = 0;
  a.callVoid(() => {
    called++;
  });
  t.is(called, 1);
});

test("partial conversion and string enum allocations are reclaimed", (t) => {
  const before = a.activeBytes();
  for (let i = 0; i < 100; i++) {
    t.throws(() => a.nested({ text: "abc", count: "bad" }));
    t.throws(() =>
      a.nestedArray([
        { text: "abc", count: 1 },
        { text: "def", count: "bad" },
      ]),
    );
    a.enumInput("A");
  }
  t.is(a.activeBytes(), before);
});

test("owned synchronous return allocations are reclaimed", (t) => {
  const before = a.activeBytes();
  for (let i = 0; i < 100; i++) t.is(a.allocateReturn(), "returned-allocation");
  t.is(a.activeBytes(), before);
});

test("class factories, static methods and value receivers preserve values", (t) => {
  t.is(a.Class.twice(3), 6);
  t.is(a.Class.make(42).value, 42);
  t.is(a.NoInit.make(42).value, 42);
  t.is(new a.Class(7).read(), 7);
  t.throws(() => new a.NoInit());
});

test("class setter and failed constructor do not retain replaced fields", (t) => {
  const instance = new a.TextClass("abc", 1);
  const before = a.activeBytes();
  for (let i = 0; i < 100; i++) {
    instance.text = "def";
    t.throws(() => new a.TextClass("abc", "bad"));
  }
  t.is(instance.text, "def");
  t.is(a.activeBytes(), before);
});

test("async borrowed literals and uncaptured input are safe", async (t) => {
  t.is(await a.asyncUnused("abc", 7), 7);
  t.is(await a.asyncLiteral(), "literal");
  if (process.env.NAPI_RS_FORCE_WASI) return;
  const result = child(`(async()=>{const assert=require('assert');const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(setImmediate)}};await collect();const before=a.activeBytes();for(let i=0;i<100;i++)assert.strictEqual(await a.asyncUnused('abc',7),7);await collect();assert.strictEqual(a.activeBytes(),before)})().catch(e=>{console.error(e);process.exitCode=1});`, ["--expose-gc"]);
  t.is(result.status, 0, result.stderr);
});

test("async Result error settles as rejection", async (t) => {
  const result = await Promise.race([
    a.asyncError().then(
      () => "resolved",
      (e) => e.message,
    ),
    new Promise((resolve) => setTimeout(() => resolve("timeout"), 1000)),
  ]);
  t.is(result, "expected rejection");
});

test("deferred settlement rejects repeat, copied and foreign capabilities", (t) => {
  const result = child(
    `const assert=require('assert');assert.throws(()=>a.doubleResolve());assert.throws(()=>a.copiedResolve());assert.throws(()=>a.resolveForeign(Promise.resolve(1)));`,
  );
  t.is(result.status, 0, result.stderr);
  t.is(result.signal, null);
});

test("AbortSignal leaves pre-existing handlers intact and rejects foreign wraps", (t) => {
  if (typeof AbortController === "undefined") {
    t.pass();
    return;
  }
  const controller = new AbortController();
  let called = 0;
  controller.signal.onabort = () => {
    called++;
  };
  a.bindSignal(controller.signal);
  controller.abort();
  t.is(called, 1);
  t.throws(() => a.bindSignal(new a.Class(1)));
});

test("class factories remain bound to their environment after Worker loading", (t) => {
  if (process.env.NAPI_RS_FORCE_WASI) {
    t.pass();
    return;
  }
  const worker = `require(${JSON.stringify(loadPath)})("audit");require('worker_threads').parentPort.postMessage('ready');setTimeout(()=>{},1000)`;
  const result = child(
    `const {Worker}=require('worker_threads');const w=new Worker(${JSON.stringify(worker)},{eval:true});w.on('error',e=>{console.error(e);process.exitCode=1});w.once('message',()=>{if(a.Class.make(5).value!==5)process.exitCode=1;w.terminate()});`,
  );
  t.is(result.status, 0, result.stderr);
  t.is(result.signal, null);
});
