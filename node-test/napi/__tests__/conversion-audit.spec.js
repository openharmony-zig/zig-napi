const detachArrayBuffer = require("../../transfer-arraybuffer");
const test = require("ava");
const path = require("path");

const bindings = require(path.join(__dirname, "..", "..", "load-addon"))("conversion_audit");

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
