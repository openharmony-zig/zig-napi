// Regression coverage for the class wrapper and the binary wrappers.
//
// The addon is built from `napi/src/classes_audit.zig` with a counting
// allocator, so the allocation assertions measure real native bytes.
//
//   F05 per environment constructor references (main thread plus workers)
//   F06 static methods, factories, ClassWithoutInit construction
//   F07 constructor rollback and setter replacement ownership
//   F12 detached / invalidated backing stores
const path = require("path");
const { spawnSync } = require("child_process");
const { Worker } = require("worker_threads");
const test = require("ava");

const loadAddon = require("../../load-addon");
const audit = loadAddon("classes_audit");

test("static methods do not unwrap their receiver", (t) => {
  t.is(audit.WidgetClass.twice(3), 6);
  t.is(audit.WidgetClass.KIND, "widget");
});

test("constructor, instance method and value receiver", (t) => {
  const widget = new audit.WidgetClass(5);
  t.is(widget.value, 5);
  t.is(widget.bump(2), 7);
  t.is(widget.value, 7);
  // `pub fn read(self: T)` is documented as supported.
  t.is(widget.read(), 7);
});

test("field construction and `init` both run exactly once", (t) => {
  audit.resetWidgetInitCalls();
  const constructed = new audit.WidgetClass(5);
  t.is(audit.widgetInitCalls(), 1);
  t.is(constructed.value, 5);

  audit.resetWidgetInitCalls();
  const made = audit.WidgetClass.make(7);
  t.is(audit.widgetInitCalls(), 0, "factory must not run user init again");
  t.is(made.value, 7);
  t.true(made instanceof audit.WidgetClass);
  t.is(made.bump(1), 8);
});

test("fields keep the values a factory produced", (t) => {
  const value = new audit.TextClass("abc", 2);
  t.is(value.text, "abc");
  t.is(value.count, 2);

  const labeled = audit.LabeledClass.make("hello", 3);
  t.is(labeled.label, "hello");
  t.is(labeled.value, 3);
  t.is(labeled.describe(), "hello");

  const constructed = new audit.LabeledClass("world", 4);
  t.is(constructed.label, "world");
  t.is(constructed.describe(), "world");
});

test("ClassWithoutInit can only be constructed through a factory", (t) => {
  const value = audit.NoInitClass.make(42);
  t.is(value.value, 42);
  t.is(value.add(1), 43);
  t.throws(() => new audit.NoInitClass(1), { instanceOf: TypeError });
  t.throws(() => audit.NoInitClass(1), { instanceOf: TypeError });
});

test("receivers of another class or object are rejected", (t) => {
  const descriptor = Object.getOwnPropertyDescriptor(audit.TextClass.prototype, "text");
  t.throws(() => descriptor.get.call({}), { instanceOf: TypeError });
  t.throws(() => descriptor.get.call(new audit.WidgetClass(1)), { instanceOf: TypeError });
  t.throws(() => audit.TextClass.prototype.text, { instanceOf: TypeError });
  t.throws(() => audit.WidgetClass.prototype.bump.call({}, 1), { instanceOf: TypeError });

  const subclass = class extends audit.WidgetClass {};
  const derived = new subclass(2);
  t.is(derived.value, 2);
  t.is(derived.bump(1), 3);
});

test("a failed constructor releases the arguments it converted", (t) => {
  const before = audit.activeBytes();
  let thrown = 0;
  for (let i = 0; i < 200; i++) {
    try {
      new audit.TextClass("abc", "not a number");
    } catch {
      thrown++;
    }
  }
  t.is(thrown, 200, "every invalid construction must throw");
  t.is(audit.activeBytes() - before, 0, "converted arguments must be rolled back");
});

test("a setter releases the value it replaces", (t) => {
  const value = new audit.TextClass("abc", 1);
  const before = audit.activeBytes();
  for (let i = 0; i < 200; i++) {
    value.text = "def";
  }
  t.is(audit.activeBytes() - before, 0, "replaced field values must be released");
  t.is(value.text, "def");

  // A failed conversion keeps the previous value instead of releasing it.
  t.throws(() => {
    value.count = "not a number";
  });
  t.is(value.count, 1, "a rejected value must not replace the current one");
});

test("borrowed init inputs stay alive and are released once", (t) => {
  const nested = new audit.NestedClass({ text: "nested", count: 4 });
  t.is(nested.describe(), "nested");
  t.is(nested.total(), 4);

  // A sub-slice alias of a converted input: the wrapper owns the whole input
  // and must not release the alias separately.
  const aliased = new audit.AliasedClass("abcdef");
  t.is(aliased.view(), "bcdef");

  // An argument the type never stores is still released by the wrapper.
  const unused = new audit.UnusedArgClass(7, "discarded");
  t.is(unused.read(), 7);

  const before = audit.activeBytes();
  for (let i = 0; i < 200; i++) {
    new audit.TrackedClass("payload");
  }
  // The instances are alive, so their inputs are still allocated.
  t.true(audit.activeBytes() > before);
});

test("a type with deinit refuses to replace a field it owns", (t) => {
  const owned = new audit.DeinitOwnedClass("name", 2);
  t.is(owned.describe(), "name");

  // `name` carries native memory the type releases in `deinit`: releasing the
  // previous value here is impossible, so the replacement is refused instead of
  // leaking or freeing memory the wrapper does not own.
  t.throws(
    () => {
      owned.name = "other";
    },
    { instanceOf: TypeError },
  );
  t.is(owned.describe(), "name");

  // Plain data stays assignable.
  owned.count = 5;
  t.is(owned.count, 5);

  // Field construction installs the value, so the wrapper owns it and may
  // replace it.
  const built = new audit.FieldBuiltClass("label");
  t.is(built.label, "label");
  built.label = "other";
  t.is(built.label, "other");

  // Explicit owner contract: the field type owns itself through `deinit`.
  const explicit = new audit.ExplicitOwnerClass();
  t.is(explicit.size(), 0);
  explicit.payload = { text: "owned-by-field" };
  t.is(explicit.size(), "owned-by-field".length);
  explicit.payload = { text: "replaced" };
  t.is(explicit.size(), 8);
});

test("foreign wrapped payloads are rejected without touching their memory", (t) => {
  const binding = Object.keys(require.cache).find((key) => key.includes("classes_audit."));
  t.truthy(binding, "the audit addon must be loaded before this test");
  // Runs in a child process: a provenance bug aborts the process here instead
  // of taking the test runner down with it.
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `
      const assert = require("assert");
      const audit = require(${JSON.stringify(binding)});
      const foreign = audit.foreignObject();
      assert.throws(() => audit.WidgetClass.prototype.read.call(foreign), TypeError);
      assert.throws(() => audit.WidgetClass.prototype.bump.call(foreign, 1), TypeError);
      assert.throws(() => Object.getOwnPropertyDescriptor(audit.TextClass.prototype, "text").get.call(foreign), TypeError);
      assert.throws(() => audit.WidgetClass.prototype.read.call({}), TypeError);
      console.log("ok");
      `,
    ],
    { encoding: "utf8", timeout: 30000 },
  );
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  t.is(result.stdout.trim(), "ok");
});

test("an invalidated argument never reaches the native body", (t) => {
  const buffer = new ArrayBuffer(16);
  const view = new Uint8Array(buffer);
  view[0] = 42;
  t.is(audit.firstByte(view), 42);

  audit.resetTypedArrayCalls();
  structuredClone(buffer, { transfer: [buffer] });

  // The conversion of the detached view fails, so the exported function is not
  // called at all.
  t.throws(() => audit.firstByte(view));
  t.is(audit.typedArrayCalls(), 0, "the native body must not run for a rejected argument");
});

test("instances are finalized exactly once", (t) => {
  const binding = Object.keys(require.cache).find((key) => key.includes("classes_audit."));
  t.truthy(binding, "the audit addon must be loaded before this test");
  const result = spawnSync(
    process.execPath,
    [
      "--expose-gc",
      "-e",
      `
      const audit = require(${JSON.stringify(binding)});
      function churn() {
        for (let i = 0; i < 200; i++) {
          new audit.TextClass("abc", i);
          new audit.WidgetClass(i);
          audit.LabeledClass.make("hello", i);
          new audit.TrackedClass("payload");
          audit.OwnedClass.make("owned");
          new audit.NestedClass({ text: "nested", count: i });
          new audit.AliasedClass("abcdef");
          new audit.UnusedArgClass(i, "discarded");
        }
      }
      const settle = async () => {
        for (let i = 0; i < 20; i++) {
          global.gc();
          await new Promise((resolve) => setTimeout(resolve, 5));
        }
      };
      (async () => {
        audit.resetFinalizedCount();
        const base = audit.activeBytes();
        churn();
        await settle();
        console.log(JSON.stringify({
          delta: audit.activeBytes() - base,
          finalized: audit.finalizedCount(),
        }));
      })();
      `,
    ],
    { encoding: "utf8", timeout: 60000 },
  );
  t.is(result.status, 0, result.stderr);
  const { delta, finalized } = JSON.parse(result.stdout.trim().split("\n").pop());
  // 200 TrackedClass plus 200 OwnedClass instances declare `deinit`. A small
  // number of instances may survive a conservative collection; a per instance
  // leak would show up as a delta of tens of bytes per instance.
  t.true(finalized >= 396, `finalized ${finalized} of 400`);
  t.true(delta <= 2048, `native bytes still allocated after GC: ${delta}`);
});

test("workers and the main thread keep their own constructors", async (t) => {
  const workers = (message) => {
    const worker = new Worker(path.join(__dirname, "classes-audit-worker.js"));
    return new Promise((resolve, reject) => {
      worker.once("message", resolve);
      worker.once("error", reject);
      worker.postMessage(message);
    });
  };

  const before = new audit.WidgetClass(1);
  t.is(before.value, 1);

  const results = await Promise.all([workers(2), workers(3)]);
  t.deepEqual(results, [
    { id: 2, constructed: 2, made: 200, static: 4, noInit: 2 },
    { id: 3, constructed: 3, made: 300, static: 6, noInit: 3 },
  ]);

  // The worker definitions must not have replaced the main thread class.
  const after = new audit.WidgetClass(4);
  t.is(after.value, 4);
  t.is(after.bump(1), 5);
  t.is(audit.WidgetClass.make(11).value, 11);
  t.is(audit.NoInitClass.make(12).value, 12);
});

function detachedView() {
  const buffer = new ArrayBuffer(16);
  const view = new Uint8Array(buffer);
  view[0] = 123;
  return { buffer, view };
}

test("a worker exit releases every class reference", async (t) => {
  const binding = Object.keys(require.cache).find((key) => key.includes("classes_audit."));
  const workerSource = `
    const { parentPort, workerData } = require("worker_threads");
    const audit = require(workerData.binding);
    const keep = [];
    for (let i = 0; i < 20; i++) {
      keep.push(new audit.WidgetClass(i));
      keep.push(audit.LabeledClass.make("hello", i));
      keep.push(new audit.TrackedClass("payload"));
    }
    parentPort.postMessage(keep.length);
  `;

  const base = audit.activeBytes();
  for (let round = 0; round < 2; round++) {
    const worker = new Worker(workerSource, { eval: true, workerData: { binding } });
    await new Promise((resolve, reject) => {
      worker.once("message", resolve);
      worker.once("error", reject);
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    t.is(audit.activeBytes() - base, 0, `clean worker exit round ${round}`);

    // Terminating a worker must release the class contexts as well.
    const terminating = new Worker(workerSource, { eval: true, workerData: { binding } });
    await new Promise((resolve) => terminating.once("message", resolve));
    await terminating.terminate();
    await new Promise((resolve) => setTimeout(resolve, 100));
    t.is(audit.activeBytes() - base, 0, `terminated worker round ${round}`);
  }
});

test("typed array reads revalidate the backing store", (t) => {
  t.is(audit.firstByte(new Uint8Array([123, 1])), 123);

  // Positive control: the callback may run JavaScript without detaching.
  const live = detachedView();
  t.is(
    audit.firstByteAfterCallback(live.view, () => 0),
    123,
  );

  const detached = detachedView();
  t.throws(
    () =>
      audit.firstByteAfterCallback(detached.view, () => {
        structuredClone(detached.buffer, { transfer: [detached.buffer] });
        return 0;
      }),
    { message: /InvalidatedBackingStore/ },
  );

  // The unchecked accessor must not hand out the pointer of a view that was
  // detached while the native function was running.
  const unchecked = detachedView();
  t.is(
    audit.firstByteUncheckedAfterCallback(unchecked.view, () => {
      structuredClone(unchecked.buffer, { transfer: [unchecked.buffer] });
      return 0;
    }),
    0,
  );

  // Converting an already detached view again is rejected up front, by the
  // conversion layer, before the exported function runs.
  const rejected = detachedView();
  structuredClone(rejected.buffer, { transfer: [rejected.buffer] });
  audit.resetTypedArrayCalls();
  t.throws(() => audit.firstByte(rejected.view), {
    code: "InvalidatedBackingStore",
  });
  t.is(audit.typedArrayCalls(), 0);
});

test("data view reads revalidate the backing store", (t) => {
  const buffer = new ArrayBuffer(16);
  const view = new DataView(buffer);
  view.setUint8(0, 33);
  t.is(
    audit.dataViewByteAfterCallback(view, () => 0),
    33,
  );

  t.throws(
    () =>
      audit.dataViewByteAfterCallback(view, () => {
        structuredClone(buffer, { transfer: [buffer] });
        return 0;
      }),
    { message: /InvalidatedBackingStore/ },
  );
});

test("buffer and array buffer reads revalidate the backing store", (t) => {
  const buffer = Buffer.from([9, 8, 7]);
  t.is(
    audit.bufferFirstByteAfterCallback(buffer, () => 0),
    9,
  );

  const shared = new ArrayBuffer(4);
  const sharedBuffer = Buffer.from(shared);
  sharedBuffer[0] = 9;
  t.throws(
    () =>
      audit.bufferFirstByteAfterCallback(sharedBuffer, () => {
        structuredClone(shared, { transfer: [shared] });
        return 0;
      }),
    { message: /InvalidatedBackingStore/ },
  );

  const arrayBuffer = new ArrayBuffer(4);
  new Uint8Array(arrayBuffer)[0] = 5;
  t.is(
    audit.arrayBufferFirstByteAfterCallback(arrayBuffer, () => 0),
    5,
  );
  t.throws(
    () =>
      audit.arrayBufferFirstByteAfterCallback(arrayBuffer, () => {
        structuredClone(arrayBuffer, { transfer: [arrayBuffer] });
        return 0;
      }),
    { message: /InvalidatedBackingStore/ },
  );
});

test("typed array element types and view lengths are validated", (t) => {
  t.is(audit.typedArraySum(new Uint32Array([1, 2, 3])), 6);
  t.throws(() => audit.typedArraySum(new Uint8Array([1, 2])), { instanceOf: TypeError });
  t.throws(() => audit.typedArraySum("not a typed array"), { instanceOf: TypeError });
  t.throws(() => audit.typedArrayOverflow(new ArrayBuffer(16)));
  t.throws(() => audit.dataViewOverflow(new ArrayBuffer(16)), { instanceOf: RangeError });
  t.throws(() => audit.dataViewOverflow("nope"), { instanceOf: TypeError });
});
