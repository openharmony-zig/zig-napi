const test = require("ava");
const path = require("path");
const { spawnSync } = require("child_process");
const loadPath = path.join(__dirname, "..", "..", "load-addon.js");
const a = require(loadPath)("audit");
const existing = require(loadPath)("example");
const detachArrayBuffer = require("../../transfer-arraybuffer");
const nativeOnlyTest = process.env.NAPI_RS_FORCE_WASI ? test.skip : test;

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
  t.throws(() => a.genericNumber("bad"));
  t.is(a.genericNumber(42), 42);
  const promise = Promise.resolve(7);
  t.is(a.borrowedPromise(promise), promise);
  t.throws(() => a.borrowedPromise({}));
  t.throws(() => existing.call0(() => "oops"));
  t.is(a.string("ok"), "ok");
  t.is(
    existing.call0(() => 17),
    17,
  );
});

test("foreign native payloads are rejected before dereference", (t) => {
  const result = child(`const assert=require('assert');const foreign=a.foreignObject();
    assert.throws(()=>a.unwrapForeign(foreign));
    assert.throws(()=>a.acceptExternal(a.foreignExternal()));
    assert.throws(()=>a.Class.prototype.read.call(foreign));`);
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
});

nativeOnlyTest("last threaded environment can retire and restart its runtime repeatedly", (t) => {
  const result = child(`const {Worker}=require('worker_threads');
    const source=${JSON.stringify(`const {parentPort}=require('worker_threads');
      const a=require(${JSON.stringify(loadPath)})('audit');
      a.asyncError().catch(()=>parentPort.postMessage('ready'));`)};
    (async()=>{for(let i=0;i<20;i++){
      const worker=new Worker(source,{eval:true});
      await new Promise((resolve,reject)=>{worker.once('error',reject);worker.once('message',resolve)});
      await worker.terminate();
    }})().catch(e=>{console.error(e);process.exitCode=1});`);
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
});

test("binary views revalidate their backing store after JavaScript reentry", (t) => {
  t.false(a.emptyBufferIsDetached());
  t.is(
    a.typedAfterCallback(new Uint8Array(0), () => {}),
    0,
  );
  const array = new Uint8Array([42]);
  t.throws(() => a.typedAfterCallback(array, () => detachArrayBuffer(array.buffer)));
  const view = new DataView(new ArrayBuffer(1));
  const backing = view.buffer;
  t.throws(() => a.dataAfterCallback(view, () => detachArrayBuffer(backing)));
  t.is(
    a.typedAfterCallback(new Uint8Array([7]), () => {}),
    7,
  );
});

nativeOnlyTest("example async heap results and parallel reads release owned allocations", (t) => {
  const result = child(
    `
    const fs=require('fs'),path=require('path'),os=require('os'),assert=require('assert');
    const dir=fs.mkdtempSync(path.join(os.tmpdir(),'zig-napi-files-'));
    const file=path.join(dir,'input.txt');fs.writeFileSync(file,'hello');
    const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(r=>setImmediate(r));}};
    async function run(){
      assert.strictEqual(await a.readFile(file),'hello');
      assert.deepStrictEqual(await a.readSummary(file),{path:file,bytes:5,text:'hello'});
      assert.deepStrictEqual(await a.readParallel({first_path:file,second_path:file,preview_bytes:2}),
        {first_bytes:5,second_bytes:5,total_bytes:10,preview:'he\\n---\\nhe'});
      const summary=await a.memorySummary({label:'abc',values:[1,2,3]});
      assert.strictEqual(summary.label,'abc');assert.strictEqual(summary.total,6);
      const custom=await a.memoryCustom('custom');
      assert.strictEqual(custom.owned_label,'custom:owned');
      await assert.rejects(a.readParallel({first_path:file,second_path:file+'.missing',preview_bytes:2}));
    }
    (async()=>{try{await run();await collect();const before=a.activeBytes();
      for(let i=0;i<50;i++)await run();await collect();assert.strictEqual(a.activeBytes(),before);
    }finally{fs.unlinkSync(file);fs.rmdirSync(dir);}})().catch(e=>{console.error(e);process.exitCode=1});
  `,
    ["--expose-gc"],
  );
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
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
  t.throws(() => a.Class.call({}, 1), { instanceOf: TypeError });
  t.is(a.Class.twice(3), 6);
  t.is(a.Class.make(42).value, 42);
  t.is(a.NoInit.make(42).value, 42);
  t.is(new a.Class(7).read(), 7);
  t.throws(() => new a.NoInit());
});

test("class returns and setters preserve explicit ownership and allocator origin", (t) => {
  const state = new a.Class(1);
  const text = new a.TextClass("abc", 1);
  const before = a.activeBytes();
  for (let i = 0; i < 100; i++) t.is(state.allocatedText(), "class-owned");
  t.is(a.activeBytes(), before);
  const alternateBefore = a.alternateBytes();
  a.useAlternateAllocator(true);
  try {
    text.text = "def";
  } finally {
    a.useAlternateAllocator(false);
  }
  t.is(a.alternateBytes(), alternateBefore);
  t.is(a.activeBytes(), before);
  t.is(text.text, "def");
});

test("class constructor and factory allocation failures roll back borrowed inputs once", (t) => {
  if (process.env.NAPI_RS_FORCE_WASI) return t.pass();
  const result = child(
    `const assert=require('assert');
    const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(r=>setImmediate(r));}};
    (async()=>{await collect();const before=a.activeBytes();
      for(let cycle=0;cycle<20;cycle++)for(let i=0;i<5;i++){
        a.setAllocationFailure(i);try{new a.BorrowedClass('abc');}catch{}finally{a.useAlternateAllocator(false);}
        a.setAllocationFailure(i);try{a.BorrowedClass.make('abc');}catch{}finally{a.useAlternateAllocator(false);}
      }
      await collect();assert.strictEqual(a.activeBytes(),before);
    })().catch(e=>{console.error(e);process.exitCode=1});`,
    ["--expose-gc"],
  );
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
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
  const result = child(
    `(async()=>{const assert=require('assert');const collect=async()=>{for(let i=0;i<5;i++){global.gc();await new Promise(setImmediate)}};await collect();const before=a.activeBytes();for(let i=0;i<100;i++)assert.strictEqual(await a.asyncUnused('abc',7),7);await collect();assert.strictEqual(a.activeBytes(),before)})().catch(e=>{console.error(e);process.exitCode=1});`,
    ["--expose-gc"],
  );
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
