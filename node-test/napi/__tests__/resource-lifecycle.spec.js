const test = require("ava");
const path = require("path");
const { spawnSync } = require("child_process");
const loadPath = path.join(__dirname, "..", "..", "load-addon.js");
const a = require(loadPath)("contracts");
const asyncTasks = require(loadPath)("async_tasks");
const isWasi =
  process.env.NAPI_RS_FORCE_WASI === "error" || process.env.NAPI_RS_FORCE_WASI === "true";
const nativeTest = isWasi ? test.skip : test;
const weakTest = !isWasi && typeof WeakRef !== "undefined" ? test : test.skip;

function isolated(body, flags = []) {
  return spawnSync(
    process.execPath,
    [
      ...flags,
      "-e",
      `
    const assert=require('assert');
    const a=require(${JSON.stringify(loadPath)})('contracts');
    const asyncTasks=require(${JSON.stringify(loadPath)})('async_tasks');
    const collect=async()=>{for(let i=0;i<10;i++){await new Promise(r=>setImmediate(r));global.gc();}};
    ${body}
  `,
    ],
    { encoding: "utf8", timeout: 12000 },
  );
}

function survived(t, result) {
  t.is(result.error, undefined, result.error && result.error.message);
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
}

nativeTest("Worker termination keeps in-flight producers alive until they finish", (t) => {
  const result = isolated(`
    const {Worker}=require('worker_threads');
    (async()=>{
      for(const withSignal of [false,true]){
        if(withSignal && typeof AbortController==='undefined')continue;
        for(let round=0;round<3;round++){
          const source=\`const {parentPort}=require('worker_threads');
            const a=require(${JSON.stringify(loadPath)})('async_tasks');
            \${withSignal ? 'a.asyncAbortable(200000000,new AbortController().signal)' : 'a.asyncLongThreadValue(5)'}.catch(()=>{});
            parentPort.postMessage('started');\`;
          const worker=new Worker(source,{eval:true});
          await new Promise((r,j)=>{worker.once('message',r);worker.once('error',j)});
          await worker.terminate();
        }
        // Previously the child exited before detached native workers touched
        // their freed operation again. Keep the process alive to observe them.
        await new Promise(r=>setTimeout(r,2000));
      }
      console.log('survived-after-producers');
    })().catch(e=>{console.error(e);process.exitCode=1});
  `);
  survived(t, result);
  t.true(result.stdout.includes("survived-after-producers"));
});

nativeTest("terminating an environment with queued events releases records and futures", (t) => {
  const result = isolated(
    `
    const {Worker}=require('worker_threads');
    (async()=>{
      await asyncTasks.asyncSliceEvents(1,()=>{});await collect();
      const before=asyncTasks.activeBytes();
      for(let round=0;round<10;round++){
        const source=\`const {parentPort}=require('worker_threads');
          const a=require(${JSON.stringify(loadPath)})('async_tasks');
          a.asyncSliceEvents(100000,()=>{}).catch(()=>{});
          parentPort.postMessage('started');
          const until=Date.now()+500;while(Date.now()<until){};\`;
        const worker=new Worker(source,{eval:true});
        await new Promise((r,j)=>{worker.once('message',r);worker.once('error',j)});
        await new Promise(r=>setTimeout(r,25));
        await worker.terminate();
      }
      await new Promise(r=>setTimeout(r,1000));await collect();
      assert.strictEqual(asyncTasks.activeBytes(),before);
    })().catch(e=>{console.error(e);process.exitCode=1});
  `,
    ["--expose-gc"],
  );
  survived(t, result);
});

nativeTest("Worker captures converted slice input before the export returns", (t) => {
  const result = isolated(`
    (async()=>{
      for(let i=0;i<20;i++)assert.strictEqual(await a.workerCapturedInput('a'.repeat(1024)),97);
    })().catch(e=>{console.error(e);process.exitCode=1});
  `);
  survived(t, result);
});

nativeTest("fire-and-forget Worker releases explicit Owned results", (t) => {
  const result = isolated(
    `
    (async()=>{
      await collect();const before=a.activeBytes();
      const target=a.workerOwnedCompletions()+100;
      for(let i=0;i<100;i++)a.workerOwnedQueue();
      const deadline=Date.now()+5000;
      while(a.workerOwnedCompletions()<target && Date.now()<deadline)await new Promise(r=>setTimeout(r,10));
      assert.strictEqual(a.workerOwnedCompletions(),target);await collect();
      assert.strictEqual(a.activeBytes(),before);
    })().catch(e=>{console.error(e);process.exitCode=1});
  `,
    ["--expose-gc"],
  );
  survived(t, result);
});

for (const method of ["tsfnError", "tsfnEmptyError"]) {
  nativeTest(`${method} delivers valid handles and owns queued error text`, (t) => {
    const result = isolated(`
      a.${method}((error)=>{assert.strictEqual(error.message,'original msg');console.log('delivered')});
    `);
    survived(t, result);
    t.true(result.stdout.includes("delivered"));
  });
}

nativeTest("later argument failure releases the already-created TSFN", (t) => {
  const result = isolated(`
    assert.throws(()=>asyncTasks.queueThreadSafeFunction(()=>{},'bad',1));
    console.log('caught');
  `);
  // No timer/process.exit: an unreleased TSFN keeps this child alive forever.
  survived(t, result);
  t.true(result.stdout.includes("caught"));
});

for (const nested of [false, true]) {
  weakTest(
    `failed ${nested ? "nested" : "positional"} conversion rolls back strong references`,
    (t) => {
      const result = isolated(
        `
      let references=[];
      for(let i=0;i<100;i++){
        const value={payload:new ArrayBuffer(65536)};
        references.push(new WeakRef(value));
        assert.throws(()=>${nested ? "a.referenceNested({reference:value,number:'bad'})" : "a.referenceThenInvalid(value,'bad')"});
      }
      (async()=>{await collect();assert.strictEqual(references.filter(r=>r.deref()).length,0)})()
        .catch(e=>{console.error(e);process.exitCode=1});
    `,
        ["--expose-gc"],
      );
      survived(t, result);
    },
  );
}

test("omitted event listener behaves like explicit undefined and null", async (t) => {
  t.is(await asyncTasks.asyncSliceEvents(1), 1);
  t.is(await asyncTasks.asyncSliceEvents(1, undefined), 1);
  t.is(await asyncTasks.asyncSliceEvents(1, null), 1);
});

test("outer rollback does not revoke an independently committed reentrant reference", (t) => {
  const saved = { marker: "inner call owns this reference" };
  t.throws(() =>
    a.nested({
      get text() {
        a.saveReference(saved);
        return "outer input";
      },
      count: "bad",
    }),
  );
  t.is(a.takeSavedReference(), saved);
});

test("event listener rejection preserves arbitrary JavaScript thrown values", async (t) => {
  for (const reason of [
    42,
    "boom",
    null,
    undefined,
    { tag: "object" },
    new Error("object error"),
  ]) {
    const outcome = await asyncTasks
      .asyncThrowingEvents(1, () => {
        throw reason;
      })
      .then(
        (value) => ({ resolved: true, value }),
        (value) => ({ resolved: false, value }),
      );
    t.false(outcome.resolved);
    t.is(outcome.value, reason);
  }
});

test("AbortSignal removal exceptions do not leave the task pending", async (t) => {
  const cleanupError = new Error("remove failed");
  const signal = {
    aborted: false,
    addEventListener() {},
    removeEventListener() {
      throw cleanupError;
    },
  };
  let timer;
  const outcome = await Promise.race([
    asyncTasks.asyncAbortable(0, signal).then(
      (value) => ({ state: "resolved", value }),
      (value) => ({ state: "rejected", value }),
    ),
    new Promise((resolve) => {
      timer = setTimeout(() => resolve({ state: "timeout" }), 2000);
    }),
  ]);
  clearTimeout(timer);
  t.not(outcome.state, "timeout");
  // Cleanup is permitted to reject with its own error if no prior task failure
  // exists, or to preserve the successful task result. It cannot hang or leak
  // an uncaught JS exception out of the completion callback.
  if (outcome.state === "resolved") t.is(outcome.value, 0);
  else t.is(outcome.value, cleanupError);
});

test("Worker capture also works with an empty input", async (t) => {
  t.is(await a.workerCapturedInput(""), 0);
});

test("unobserved progress does not allocate a payload for every event", async (t) => {
  await asyncTasks.asyncSliceEvents(1, undefined);
  const before = asyncTasks.allocationCount();
  t.is(await asyncTasks.asyncSliceEvents(10000, undefined), 10000);
  const allocations = asyncTasks.allocationCount() - before;
  t.true(allocations < 128, `unobserved events caused ${allocations} allocations`);
});

for (const route of ["manual", "constructor", "factory", "method", "fields"]) {
  weakTest(`${route} conversion failure rolls back JavaScript resources`, (t) => {
    const expression = {
      manual: "a.manualReferenceConversion({reference:value,number:'bad'})",
      constructor: "new a.ReferenceCalls(value,'bad',{})",
      factory: "a.ReferenceCalls.make(value,'bad',{})",
      method: "instance.consume(value,'bad',{})",
      fields: "new a.ReferenceFields(value,'bad')",
    }[route];
    const result = isolated(
      `
      const instance=new a.ReferenceCalls({},1,{});
      const references=[];
      for(let i=0;i<100;i++){
        const value={payload:new ArrayBuffer(65536)};
        references.push(new WeakRef(value));
        assert.throws(()=>${expression});
      }
      (async()=>{await collect();assert.strictEqual(references.filter(r=>r.deref()).length,0)})()
        .catch(e=>{console.error(e);process.exitCode=1});
    `,
      ["--expose-gc"],
    );
    survived(t, result);
  });
}

nativeTest("transient Class inputs are released while instances remain reachable", (t) => {
  const result = isolated(
    `
    (async()=>{
      await collect();const before=a.activeBytes();
      let values=[];
      for(let i=0;i<100;i++){
        const text='x'.repeat(65536);
        values.push(i%2 ? a.TransientSummary.make(text) : new a.TransientSummary(text));
      }
      await collect();
      assert(values.every(value=>value.length===65536));
      const retained=a.activeBytes()-before;
      assert(retained<100000,'retained '+retained+' bytes for scalar-only instances');
      assert.strictEqual(a.TransientSummary.arg_ownership,undefined);
      values=null;await collect();assert.strictEqual(a.activeBytes(),before);
    })().catch(e=>{console.error(e);process.exitCode=1});
  `,
    ["--expose-gc"],
  );
  survived(t, result);
});

test("Worker Promise allocation failure releases captured inputs and native work", (t) => {
  const before = a.activeBytes();
  for (let i = 0; i < 100; i++) t.throws(() => a.workerPromiseAllocationFailure("x".repeat(1024)));
  t.is(a.activeBytes(), before);
});

nativeTest("first instance-method argument failure never cleans uninitialized data", (t) => {
  survived(
    t,
    isolated(`
    const value=new a.BorrowedClass('kept alive');
    for(let i=0;i<100;i++)assert.throws(()=>value.textLength(42));
    assert.strictEqual(value.textLength('valid'),5);
  `),
  );
});

nativeTest("zero-argument factory resources survive an outer conversion rollback", (t) => {
  survived(
    t,
    isolated(`
    const saved={marker:'factory owns replacement'};
    a.saveReference(saved);
    assert.throws(()=>a.nested({get text(){a.ReferenceCalls.makeSaved();return 'outer'},count:'bad'}));
    assert.strictEqual(a.takeSavedReference(),saved);
  `),
  );
});
