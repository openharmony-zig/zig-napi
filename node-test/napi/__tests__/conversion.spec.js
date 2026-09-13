const detachArrayBuffer = require("../../transfer-arraybuffer");
const test = require("ava");
const path = require("path");

const bindings = require(path.join(__dirname, "..", "..", "load-addon"))("conversion");

const loaderPath = path.join(__dirname, "..", "..", "load-addon.js");

// `require("node:...")` prefixes are not available on every Node version this
// suite supports, so the built-in module is required lazily.
function childProcess() {
  return require("child_process");
}

const isWasi =
  process.env.NAPI_RS_FORCE_WASI === "true" || process.env.NAPI_RS_FORCE_WASI === "error";
// Tests that need a child process, native threads or a forced GC are not part
// of the WASI runtime and are skipped there instead of pretending to cover it.
const nativeOnlyTest = isWasi ? test.skip : test;

function runIsolated(script, extraArgs = []) {
  return childProcess().spawnSync(
    process.execPath,
    [...extraArgs, "-e", `const b=require(${JSON.stringify(loaderPath)})("conversion");${script}`],
    { encoding: "utf8", timeout: 20000 },
  );
}

// Wait for the native counters to stop changing: released thread-safe functions
// are destroyed by the runtime on a later loop turn (their finalizer releases
// the wrapper), so a baseline measured too early would still move.
async function stableCounters() {
  let last = [bindings.activeBytes(), bindings.activeAllocations()];
  for (let attempt = 0; attempt < 50; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
    const now = [bindings.activeBytes(), bindings.activeAllocations()];
    if (now[0] === last[0] && now[1] === last[1]) return now;
    last = now;
  }
  return last;
}

// Wait until a counter stopped growing past its baseline. Anything the test
// released must be reclaimed; earlier tests releasing their own wrappers may
// pull the counter below the baseline, which is not a failure.
async function settlesToBaseline(read, baseline, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (read() <= baseline) return true;
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("rejects wrong argument types without running the native function", (t) => {
  bindings.resetNativeCallCount();

  t.throws(() => bindings.add("1", 2), { name: "TypeError" });
  t.throws(() => bindings.add(1), { name: "TypeError" });
  t.throws(() => bindings.add(1.5, 2), { name: "TypeError" });
  t.is(bindings.nativeCallCount(), 0);

  t.is(bindings.add(1, 2), 3);
  t.is(bindings.nativeCallCount(), 1);
});

test("propagates the original exception thrown by a getter", (t) => {
  bindings.resetNativeCallCount();

  const original = new Error("getter boom");
  const point = {
    get x() {
      throw original;
    },
    y: 2,
  };

  const thrown = t.throws(() => bindings.translatePoint(point, 1, 2));
  t.is(thrown, original);
  t.is(thrown.message, "getter boom");
  t.is(bindings.nativeCallCount(), 0);

  // The environment stays usable afterwards.
  t.deepEqual(bindings.translatePoint({ x: 1, y: 2 }, 1, 2), { x: 2, y: 4 });
  t.is(bindings.nativeCallCount(), 1);
});

test("string conversion failures are reported instead of returning empty strings", (t) => {
  bindings.resetNativeCallCount();

  t.throws(() => bindings.roundtripStr(123), { name: "TypeError" });
  t.throws(() => bindings.roundtripStr(), { name: "TypeError" });
  t.is(bindings.nativeCallCount(), 0);

  t.is(bindings.roundtripStr("ok"), "ok");
  t.is(bindings.stringLength("abc"), 3);
});

test("checked numeric conversions", (t) => {
  t.is(bindings.unsignedRoundtrip(0), 0);
  t.is(bindings.unsignedRoundtrip(9007199254740992), 9007199254740992);
  t.throws(() => bindings.unsignedRoundtrip(-1), { name: "RangeError" });
  t.throws(() => bindings.unsignedRoundtrip(1.5), { name: "TypeError" });
  t.throws(() => bindings.unsignedRoundtrip(NaN), { name: "TypeError" });
  t.throws(() => bindings.unsignedRoundtrip(Infinity), { name: "TypeError" });

  // maxInt(u64) must not be narrowed to i64; it is emitted as a JS number.
  const max = bindings.maxUnsigned();
  t.is(typeof max, "number");
  t.is(max, 18446744073709551616);

  t.is(bindings.signedRoundtrip(-9007199254740991), -9007199254740991);
  t.throws(() => bindings.signedRoundtrip(2 ** 63), { name: "RangeError" });
  // -2^63 itself is representable and valid; twice that is not.
  t.is(bindings.signedRoundtrip(-(2 ** 63)), -(2 ** 63));
  t.throws(() => bindings.signedRoundtrip(-(2 ** 63) * 2), { name: "RangeError" });

  t.is(bindings.narrowRoundtrip(0), 0);
  t.is(bindings.narrowRoundtrip(255), 255);
  t.throws(() => bindings.narrowRoundtrip(256), { name: "RangeError" });
  t.throws(() => bindings.narrowRoundtrip(-1), { name: "RangeError" });

  t.is(bindings.doubleRoundtrip(Number.NaN), Number.NaN);
  t.is(bindings.doubleRoundtrip(Infinity), Infinity);
  t.is(bindings.floatRoundtrip(1.5), 1.5);
  t.throws(() => bindings.floatRoundtrip(1e300), { name: "RangeError" });
});

test("enum values are validated before narrowing the tag", (t) => {
  t.is(bindings.enumRoundtrip(1), 1);
  // Previously aborted the process with an out of range int cast.
  t.throws(() => bindings.enumRoundtrip(256), { name: "TypeError" });
  t.throws(() => bindings.enumRoundtrip(0), { name: "TypeError" });
  t.throws(() => bindings.enumRoundtrip(1.5), { name: "TypeError" });
  t.throws(() => bindings.enumRoundtrip("1"), { name: "TypeError" });

  t.is(bindings.stringEnumRoundtrip("Ready"), "Ready");
  t.throws(() => bindings.stringEnumRoundtrip("Missing"), { name: "TypeError" });
  t.throws(() => bindings.stringEnumRoundtrip(1), { name: "TypeError" });
});

test("failed nested conversions roll back every allocation", (t) => {
  const baseline = bindings.activeBytes();

  for (let i = 0; i < 10000; i += 1) {
    t.throws(() => bindings.nested({ text: "abc", count: "bad" }));
  }
  for (let i = 0; i < 2000; i += 1) {
    t.throws(() =>
      bindings.nestedArray([
        { text: "abc", count: 1 },
        { text: "def", count: "bad" },
      ]),
    );
  }
  for (let i = 0; i < 10000; i += 1) {
    t.throws(() => bindings.nestedOptional({ text: "abc", count: "bad" }));
  }
  for (let i = 0; i < 10000; i += 1) {
    t.throws(() => bindings.stringEnumRoundtrip("Missing"));
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("union and optional arguments pick a matching variant or fail", (t) => {
  t.is(bindings.unionRoundtrip(3), 3);
  t.is(bindings.unionRoundtrip("abcd"), 4);
  t.throws(() => bindings.unionRoundtrip(true), { name: "TypeError" });
  t.throws(() => bindings.unionRoundtrip({}), { name: "TypeError" });

  t.is(bindings.nestedOptional(null), 0);
  t.is(bindings.nestedOptional({ text: "ab", count: 1 }), 3);
});

test("successful nested conversions release their argument copies", (t) => {
  const baseline = bindings.activeBytes();

  for (let i = 0; i < 10000; i += 1) {
    t.is(bindings.nested({ text: "abc", count: 1 }), 4);
  }
  for (let i = 0; i < 2000; i += 1) {
    t.is(
      bindings.nestedArray([
        { text: "abc", count: 1 },
        { text: "def", count: 2 },
      ]),
      9,
    );
  }
  for (let i = 0; i < 10000; i += 1) {
    t.is(bindings.stringEnumRoundtrip("Poll"), "Poll");
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("more than 128 element copies are all released", (t) => {
  const baseline = bindings.activeBytes();

  // The legacy cleanup path deduplicated at most 128 addresses; the explicit
  // ownership path has no such limit.
  const input = Array.from({ length: 256 }, (_, index) => ({ text: `t${index}`, count: 1 }));
  for (let i = 0; i < 50; i += 1) {
    t.true(bindings.nestedArray(input) > 0);
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("plain returns are borrowed, owned returns are released", (t) => {
  const baseline = bindings.activeBytes();

  t.is(bindings.literalReturn(), "literal");
  t.is(bindings.passthroughReturn("borrowed"), "borrowed");
  t.is(bindings.subsliceReturn("borrowed"), "orrowed");

  for (let i = 0; i < 200; i += 1) {
    t.is(bindings.allocateReturn(), "returned-allocation");
  }
  for (let i = 0; i < 200; i += 1) {
    t.deepEqual(bindings.ownedStructReturn(), { text: "owned-struct", count: 7 });
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("owned arguments are released by the call scope", (t) => {
  const baseline = bindings.activeBytes();

  for (let i = 0; i < 200; i += 1) {
    t.is(bindings.ownedStructText({ text: "abc", count: 1 }), 3);
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("nested Owned nodes are released on success and on conversion failure", (t) => {
  const baseline = bindings.activeBytes();
  const baselineAllocations = bindings.activeAllocations();

  t.deepEqual(bindings.ownedPairReturn(), { text: "pair", count: 3 });
  t.deepEqual(Array.from(bindings.ownedFixedArrayReturn()), ["first", "second"]);
  t.is(bindings.ownedOptionalReturn(true), "optional");
  t.is(bindings.ownedOptionalReturn(false), undefined);

  // The container is borrowed, but the nested Owned field must still be freed
  // even though the output conversion fails.
  t.throws(() => bindings.ownedWithFailingOutput());

  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), baselineAllocations);
});

test("owned values are released by the allocator that produced them", (t) => {
  const baselineDefault = bindings.activeBytes();
  const baselineAlt = bindings.activeAltBytes();

  for (let i = 0; i < 100; i += 1) {
    t.is(bindings.allocateWithAlternateAllocator(), "alternate");
  }

  t.is(bindings.activeAltBytes(), baselineAlt);
  t.is(bindings.activeAltAllocations(), 0);
  t.is(bindings.activeBytes(), baselineDefault);
});

test("wrapped payloads are released by the allocator that created them", (t) => {
  const baselineDefault = bindings.activeBytes();
  const baselineAlt = bindings.activeAltBytes();

  for (let i = 0; i < 100; i += 1) {
    const wrapped = bindings.alternateAllocatorWrapProbe();
    // Same destroy path the GC finalizer uses.
    bindings.releaseWrapProbe(wrapped);
  }

  t.is(bindings.activeAltBytes(), baselineAlt);
  t.is(bindings.activeAltAllocations(), 0);
  t.is(bindings.activeBytes(), baselineDefault);
});

test("a reentrant callback that switches allocators cannot break cleanup", (t) => {
  const baselineDefault = bindings.activeBytes();
  const baselineAlt = bindings.activeAltBytes();

  for (let i = 0; i < 100; i += 1) {
    try {
      // The callback leaves this thread's operation allocator switched for the
      // rest of the outer call, so the outer argument cleanup would mismatch if
      // the allocator were not captured when the call started.
      t.is(
        bindings.allocatorProbe({ text: "abc", count: 1 }, () =>
          bindings.useAlternateOperationAllocator(),
        ),
        4,
      );
    } finally {
      bindings.useDefaultOperationAllocator();
    }
  }

  t.true(bindings.currentOperationAllocatorIsDefault());
  t.is(bindings.activeBytes(), baselineDefault);
  t.is(bindings.activeAltBytes(), baselineAlt);
});

test("deep clones do not share memory with their source", (t) => {
  const baseline = bindings.activeBytes();

  for (let i = 0; i < 200; i += 1) {
    t.deepEqual(bindings.clonedReturn({ text: "abc", count: 1 }), { text: "abc", count: 1 });
  }
  for (let i = 0; i < 200; i += 1) {
    t.deepEqual(bindings.clonedArrayReturn(["a", "bb"]), ["a", "bb"]);
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("fixed size array and string inputs", (t) => {
  t.is(bindings.fixedInts([1, 2]), 3);
  t.throws(() => bindings.fixedInts([1]), { name: "RangeError" });
  t.throws(() => bindings.fixedInts([1, 2, 3]), { name: "RangeError" });
  t.throws(() => bindings.fixedInts("ab"), { name: "TypeError" });

  t.is(bindings.fixedBytes("ab"), 97 * 10 + 98);
  t.is(bindings.fixedBytes([97, 98]), 97 * 10 + 98);
  t.throws(() => bindings.fixedBytes("abc"), { name: "RangeError" });
  t.throws(() => bindings.fixedBytes("a"), { name: "RangeError" });

  t.is(bindings.fixedUtf16("ab"), 97 + 98);
  t.throws(() => bindings.fixedUtf16("a"), { name: "RangeError" });
});

test("void callbacks and callback return conversion", (t) => {
  t.is(
    bindings.callVoid(() => {}),
    undefined,
  );
  const thrown = t.throws(() =>
    bindings.callVoid(() => {
      throw new Error("callboom");
    }),
  );
  t.is(thrown.message, "callboom");

  t.is(
    bindings.callNumber(() => 42),
    42,
  );
  t.throws(() => bindings.callNumber(() => "oops"), { name: "TypeError" });

  // The exception thrown by a callback does not corrupt later calls.
  t.is(
    bindings.callNumber(() => 7),
    7,
  );
});

test("empty strings round trip without leaking", (t) => {
  const baseline = bindings.activeBytes();

  for (let i = 0; i < 2000; i += 1) {
    t.is(bindings.stringLength(""), 0);
    t.is(bindings.roundtripStr(""), "");
  }
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), 0);
});

test("detached binary inputs are rejected before the native body runs", (t) => {
  if (!bindings.supportsBinaryTryFromRaw()) {
    // The wrappers in this build do not validate their backing store yet; the
    // class-owned migration adds `tryFromRaw` and this test then runs for real.
    t.pass("binary wrappers do not expose tryFromRaw in this build");
    return;
  }

  bindings.resetNativeCallCount();

  const buffer = new ArrayBuffer(8);
  const view = new Uint8Array(buffer);
  view[0] = 123;
  t.is(bindings.firstByte(view), 123);

  // Detach the backing store through a structured clone transfer.
  detachArrayBuffer(buffer);

  t.throws(() => bindings.firstByte(view));
  t.is(bindings.nativeCallCount(), 1);
});

test("utf16 strings survive the round trip", (t) => {
  t.is(bindings.concatUtf16("héllo 🌳"), "héllo 🌳");
});

// ---------------------------------------------------------- callback ownership

test("a queued failure owns the error text it delivers", async (t) => {
  const messages = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnErrorBorrowedText(
        (err) => {
          messages.push(err && err.message);
          if (messages.length === 3) resolve();
        },
        "queued",
        3,
      );
    } catch (error) {
      reject(error);
    }
  });

  // The native side overwrites its stack buffer right after queueing each call,
  // so a shallow copy of the borrowed message would deliver "xxxxxxxx" here.
  t.deepEqual(messages, ["queued-0", "queued-1", "queued-2"]);
});

test("the error branch of an error-first TSFN passes exactly one argument", async (t) => {
  const calls = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnErrorWithArgs(function (err) {
        calls.push({ argc: arguments.length, message: err && err.message, rest: arguments[1] });
        if (calls.length === 2) resolve();
      }, 2);
    } catch (error) {
      reject(error);
    }
  });

  // Two argument slots are declared, but the failure call passes the error
  // alone: the remaining slots must be omitted, not passed as native null
  // handles (which are not JavaScript `undefined`).
  t.deepEqual(calls, [
    { argc: 1, message: "pair-error", rest: undefined },
    { argc: 1, message: "pair-error", rest: undefined },
  ]);
});

test("an error-first TSFN without argument slots passes the error alone", async (t) => {
  const calls = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnErrorWithoutArgs(function (err) {
        calls.push({ argc: arguments.length, message: err && err.message });
        if (calls.length === 1) resolve();
      }, 1);
    } catch (error) {
      reject(error);
    }
  });

  t.deepEqual(calls, [{ argc: 1, message: "noargs-error" }]);
});

test("a TSFN without an error slot delivers undefined arguments for a failure", async (t) => {
  const failures = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnPlainError(function (value) {
        failures.push({ argc: arguments.length, value });
        if (failures.length === 1) resolve();
      }, 1);
    } catch (error) {
      reject(error);
    }
  });

  // There is no error slot to report the failure through, so the callback runs
  // with the (absent) argument slots as `undefined` - never as null handles.
  t.deepEqual(failures, [{ argc: 1, value: undefined }]);

  const values = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnPlainSuccess(
        (value) => {
          values.push(value);
          if (values.length === 2) resolve();
        },
        5,
        2,
      );
    } catch (error) {
      reject(error);
    }
  });
  t.deepEqual(values, [5, 6]);
});

nativeOnlyTest("a converted TSFN stays alive after the call that produced it", async (t) => {
  const calls = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnQueueFromThread(function (err, first, second) {
        calls.push([err, first, second]);
        if (calls.length === 3) resolve();
      }, 3);
    } catch (error) {
      reject(error);
    }
  });

  // The body hands the TSFN to a worker thread, so the conversion transaction
  // is committed when the body runs; aborting it afterwards would drop these
  // calls.
  t.deepEqual(calls, [
    [null, 0, 1],
    [null, 1, 2],
    [null, 2, 3],
  ]);
});

nativeOnlyTest("a rejected call releases the TSFN it promoted", (t) => {
  bindings.resetNativeCallCount();
  t.throws(() => bindings.tsfnThenRejected(() => {}, "bad"), { name: "TypeError" });
  t.is(bindings.nativeCallCount(), 0, "the native body must not run for a rejected argument");

  // A promoted TSFN that survived the failed call would keep the environment -
  // and therefore the process - alive forever. Running it in a child process
  // turns that leak into an observable failure: the child is killed on timeout
  // instead of exiting on its own.
  const result = runIsolated(
    `
    b.resetNativeCallCount();
    let thrown = null;
    try { b.tsfnThenRejected(() => {}, "bad"); } catch (error) { thrown = error.name; }
    console.log(JSON.stringify({ thrown, calls: b.nativeCallCount() }));
    `,
  );
  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  t.deepEqual(JSON.parse(result.stdout.trim()), { thrown: "TypeError", calls: 0 });
});

nativeOnlyTest("a rejected call releases the references it created", (t) => {
  const result = runIsolated(
    `
    const collect = async () => {
      for (let index = 0; index < 10; index += 1) {
        global.gc();
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    };
    (async () => {
      // Each attempt runs in its own call frame: a loop-local binding is still
      // rooted by the engine's stack scan when the collection runs, which would
      // report one surviving object per loop without anything having leaked.
      const attempt = (create, invoke) => {
        const object = create();
        const ref = new WeakRef(object);
        try {
          invoke(object);
        } catch (error) {
          if (!error) throw error;
        }
        return ref;
      };

      const control = [];
      for (let index = 0; index < 100; index += 1) {
        control.push(attempt(() => ({ index }), () => {}));
      }

      const plain = [];
      for (let index = 0; index < 100; index += 1) {
        plain.push(attempt(() => ({ index }), (object) => b.referenceThenRejected(object, "bad")));
      }

      const nested = [];
      for (let index = 0; index < 100; index += 1) {
        nested.push(attempt(() => ({ index }), (object) => b.nestedReferenceThenRejected({ reference: object, count: "bad" }, 0)));
      }

      const inArray = [];
      for (let index = 0; index < 100; index += 1) {
        // The element that cannot be referenced fails the whole array
        // conversion; the references created for the earlier elements must be
        // released with it.
        inArray.push(attempt(() => ({ index }), (object) => b.arrayReferenceThenRejected([object, 5], 0)));
      }

      await collect();
      const alive = (refs) => refs.filter((ref) => ref.deref() !== undefined).length;
      console.log(JSON.stringify({
        control: alive(control), plain: alive(plain), nested: alive(nested), inArray: alive(inArray),
        calls: b.nativeCallCount(),
      }));
    })();
    `,
    ["--expose-gc"],
  );

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  // Every object whose reference conversion was rolled back is collectible
  // again; the control group proves the child would have reported retained
  // objects if they were still referenced.
  t.deepEqual(JSON.parse(result.stdout.trim()), {
    control: 0,
    plain: 0,
    nested: 0,
    inArray: 0,
    calls: 0,
  });
});

nativeOnlyTest("a successful conversion transfers the reference to the body", (t) => {
  const result = runIsolated(
    `
    const collect = async () => {
      for (let index = 0; index < 10; index += 1) {
        global.gc();
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    };
    (async () => {
      let weak;
      (() => {
        const object = { kept: true };
        weak = new WeakRef(object);
        b.storeReference(object);
      })();

      await collect();
      const stored = weak.deref() !== undefined;
      const released = b.releaseStoredReference();
      const storedAfterRelease = b.storedReferenceIsSet();
      await collect();
      console.log(JSON.stringify({ stored, released, storedAfterRelease, alive: weak.deref() !== undefined }));
    })();
    `,
    ["--expose-gc"],
  );

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  // A committed conversion hands the strong reference to the body: the object
  // stays alive until the body releases it, and the rollback never touches it.
  t.deepEqual(JSON.parse(result.stdout.trim()), {
    stored: true,
    released: true,
    storedAfterRelease: false,
    alive: false,
  });
});

nativeOnlyTest("a full queue releases the payload it rejects", async (t) => {
  const baseline = await stableCounters();
  const delivered = [];
  let onDelivered;
  const delivery = new Promise((resolve) => {
    onDelivered = resolve;
  });

  const rejected = bindings.tsfnQueueOverflow(function (value) {
    delivered.push(value);
    onDelivered();
  }, 3);

  // The bounded queue holds one item; the worker's remaining calls are refused
  // and their payloads must be released instead of leaking.
  t.is(rejected, 2);
  await delivery;
  t.deepEqual(delivered, [0]);
  t.true(await settlesToBaseline(() => bindings.activeBytes(), baseline[0]));
  t.true(await settlesToBaseline(() => bindings.activeAllocations(), baseline[1]));
});

nativeOnlyTest("a closing TSFN releases the payload it rejects", async (t) => {
  const baseline = await stableCounters();
  const rejected = bindings.tsfnAbortProbe(function () {
    t.fail("an aborted TSFN must not deliver a queued call");
  }, 3);

  t.is(rejected, 3);
  t.true(await settlesToBaseline(() => bindings.activeBytes(), baseline[0]));
  t.true(await settlesToBaseline(() => bindings.activeAllocations(), baseline[1]));
});

test("a payload that cannot be converted is reported instead of dispatched", async (t) => {
  const calls = [];
  await new Promise((resolve, reject) => {
    try {
      bindings.tsfnBadOutput(function (err, value) {
        calls.push({
          argc: arguments.length,
          code: err && err.code,
          isError: err instanceof Error,
          value,
        });
        if (calls.length === 1) resolve();
      }, 1);
    } catch (error) {
      reject(error);
    }
  });

  // The queued reference was already released, so the value cannot become a
  // JavaScript handle: the callback is called with the failure in the error
  // slot and `undefined` for the value, never with an invalid handle.
  t.deepEqual(calls, [
    {
      argc: 2,
      code: "Ref value has been deleted",
      isError: true,
      value: undefined,
    },
  ]);
});

nativeOnlyTest("a throwing callback does not break later deliveries", (t) => {
  // Without this runtime option Node swallows exceptions thrown by a Node-API
  // callback and only prints a deprecation warning; the option itself is not
  // available on every Node version this suite supports.
  const strict = process.allowedNodeEnvironmentFlags.has(
    "--force-node-api-uncaught-exceptions-policy",
  );
  const script = `
    const thrown = [];
    const delivered = [];
    process.on("uncaughtException", (error) => { thrown.push(error.message); });
    b.tsfnPlainSuccess(function (value) {
      delivered.push(value);
      if (value === 0) throw new Error("callback boom");
    }, 0, 3);
    setTimeout(() => {
      console.log(JSON.stringify({ thrown, delivered }));
    }, 50);
  `;
  const result = strict
    ? runIsolated(script, ["--force-node-api-uncaught-exceptions-policy"])
    : runIsolated(script);

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout.trim());
  // A callback that throws must not poison the dispatch: the remaining queued
  // calls are still delivered, and the pending exception stays a runtime
  // concern instead of being replaced by a fresh error.
  t.deepEqual(output.delivered, [0, 1, 2]);
  if (strict) {
    t.deepEqual(output.thrown, ["callback boom"]);
  }
});

nativeOnlyTest("a manual conversion inside a native body releases what it created", (t) => {
  const result = runIsolated(
    `
    const collect = async () => {
      for (let index = 0; index < 10; index += 1) {
        global.gc();
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    };
    (async () => {
      // Same helper as the automatic-conversion regression: the object is only
      // reachable through the reference the conversion created for it.
      const attempt = (create, invoke) => {
        const object = create();
        const ref = new WeakRef(object);
        try {
          invoke(object);
        } catch (error) {
          if (!error) throw error;
        }
        return ref;
      };

      b.resetNativeCallCount();
      const refs = [];
      for (let index = 0; index < 100; index += 1) {
        refs.push(
          attempt(
            () => ({ index }),
            (object) => b.manualNestedConversion({ reference: object, count: "bad" }),
          ),
        );
      }

      await collect();
      console.log(
        JSON.stringify({
          alive: refs.filter((ref) => ref.deref() !== undefined).length,
          calls: b.nativeCallCount(),
        }),
      );
    })();
    `,
    ["--expose-gc"],
  );

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  // The struct conversion creates the reference and then fails on the next
  // field; the transaction around the manual conversion releases it.
  t.deepEqual(JSON.parse(result.stdout.trim()), { alive: 0, calls: 0 });
});

nativeOnlyTest("an inner committed reference survives a failing outer conversion", (t) => {
  const result = runIsolated(
    `
    const collect = async () => {
      for (let index = 0; index < 10; index += 1) {
        global.gc();
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    };
    (async () => {
      let thrown = null;
      let weak;
      // The object is created in its own scope so that, once the stored
      // reference is released, nothing else keeps it alive.
      (() => {
        const object = {
          get x() {
            // Reenters another exported function, which takes ownership of a
            // reference to this object and commits it.
            b.storeReference(this);
            return 1;
          },
          y: 2,
        };
        weak = new WeakRef(object);

        try {
          // The getter runs while the first argument is converted; the second
          // argument is rejected afterwards.
          b.translatePoint(object, "bad", 2);
        } catch (error) {
          thrown = error.name;
        }
      })();

      await collect();
      const stored = b.storedReferenceIsSet();
      const aliveWhileStored = weak.deref() !== undefined;
      const released = b.releaseStoredReference();
      await collect();
      console.log(
        JSON.stringify({
          thrown,
          stored,
          aliveWhileStored,
          released,
          aliveAfterRelease: weak.deref() !== undefined,
          calls: b.nativeCallCount(),
        }),
      );
    })();
    `,
    ["--expose-gc"],
  );

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  // The rejected outer call must not release a reference that another, already
  // committed call owns.
  t.deepEqual(JSON.parse(result.stdout.trim()), {
    thrown: "TypeError",
    stored: true,
    aliveWhileStored: true,
    released: true,
    aliveAfterRelease: false,
    calls: 0,
  });
});

nativeOnlyTest("a manual conversion hands its reference to the caller", (t) => {
  const result = runIsolated(
    `
    const collect = async () => {
      for (let index = 0; index < 10; index += 1) {
        global.gc();
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    };
    (async () => {
      let weak;
      (() => {
        const object = { kept: true };
        weak = new WeakRef(object);
        b.manualStoredReference(object);
      })();

      await collect();
      const stored = b.storedReferenceIsSet();
      const aliveWhileStored = weak.deref() !== undefined;
      b.releaseStoredReference();
      await collect();
      console.log(
        JSON.stringify({ stored, aliveWhileStored, aliveAfterRelease: weak.deref() !== undefined }),
      );
    })();
    `,
    ["--expose-gc"],
  );

  t.is(result.signal, null, result.stderr);
  t.is(result.status, 0, result.stderr);
  // A successful manual conversion commits its resources to the caller, exactly
  // like a successful argument conversion commits them to the native body.
  t.deepEqual(JSON.parse(result.stdout.trim()), {
    stored: true,
    aliveWhileStored: true,
    aliveAfterRelease: false,
  });
});

test("a custom native deinit runs next to the resource rollback", (t) => {
  const baseline = bindings.activeBytes();
  const baselineAllocations = bindings.activeAllocations();
  bindings.resetNativeCallCount();

  for (let index = 0; index < 50; index += 1) {
    // The struct conversion allocates its string and creates a strong reference
    // for the `reference` field; the second argument is then rejected. The
    // reference is released by the transaction and the string by the custom
    // `deinit`, each exactly once.
    t.throws(() => bindings.nativeHolderThenRejected({ text: "hello", reference: {} }, "bad"), {
      name: "TypeError",
    });
  }

  t.is(bindings.nativeCallCount(), 0, "the native body must not run for a rejected argument");
  t.is(bindings.activeBytes(), baseline);
  t.is(bindings.activeAllocations(), baselineAllocations);
});
