const test = require("ava");
const bindings = require("./binding");

test("export const", (t) => {
  t.is(bindings.DEFAULT_COST, 12);
});

test("number", (t) => {
  t.is(bindings.add(1, 2), 3);
  t.is(bindings.fibonacci(5), 5);
  t.throws(() => bindings.fibonacci(""));
});

test("string", (t) => {
  t.true(bindings.contains("hello", "ell"));
  t.false(bindings.contains("John", "jn"));

  t.is(bindings.concatStr("æ¶½¾DEL"), "æ¶½¾DEL + Rust 🦀 string!");
  t.is(bindings.concatLatin1("æ¶½¾DEL"), "æ¶½¾DEL + Rust 🦀 string!");
  t.is(
    bindings.concatUtf16("JavaScript 🌳 你好 napi"),
    "JavaScript 🌳 你好 napi + Rust 🦀 string!",
  );
  t.is(
    bindings.roundtripStr("what up?!\0after the NULL"),
    "what up?!\0after the NULL",
  );
});

test("array", (t) => {
  t.deepEqual(bindings.getNums(), [1, 1, 2, 3, 5, 8]);
  t.deepEqual(bindings.getWords(), ["foo", "bar"]);
  t.deepEqual(bindings.getTuple([1, "test", 2]), 3);
  t.is(bindings.sumNums([1, 2, 3, 4, 5]), 15);
  t.deepEqual(bindings.getNumArr(), [1, 2]);
  t.deepEqual(bindings.getNestedNumArr(), [[[1]], [[1]]]);
});

test("map", (t) => {
  t.deepEqual(bindings.getMapping(), { a: 101, b: 102, "\0c": 103 });
  t.is(bindings.sumMapping({ a: 101, b: 102, "\0c": 103 }), 306);
  t.deepEqual(bindings.indexmapPassthrough({ a: 101, b: 102, "\0c": 103 }), {
    a: 101,
    b: 102,
    "\0c": 103,
  });
});

test("enum", (t) => {
  t.deepEqual([bindings.Kind.Dog, bindings.Kind.Cat, bindings.Kind.Duck], [0, 1, 2]);
  t.is(bindings.enumToI32(bindings.CustomNumEnum.Eight), 8);
});

test("function call", (t) => {
  t.is(
    bindings.call0((...args) => {
      t.is(args.length, 0);
      return 42;
    }),
    42,
  );
  t.is(bindings.call1((a) => a + 10, 42), 52);
  t.is(bindings.call2((a, b) => a + b, 42, 10), 52);
  t.is(bindings.callFunction(() => 42), 42);
  t.is(bindings.callFunctionWithArg((a, b) => a + b, 42, 10), 52);

  const fn = bindings.createFunction();
  t.is(fn(42), 242);
});

test("object", (t) => {
  t.deepEqual(bindings.createObj(), { x: 1, y: 2 });
  t.deepEqual(bindings.translatePoint({ x: 1, y: 2 }, 3, 4), { x: 4, y: 6 });
  t.deepEqual(bindings.listObjKeys({ z: 1, a: 2 }).sort(), ["a", "z"]);
});

test("global, undefined, null and symbol", (t) => {
  t.is(bindings.getGlobal(), globalThis);
  t.is(bindings.getUndefined(), undefined);
  t.is(bindings.returnUndefined(), undefined);
  t.is(bindings.getNull(), null);
  t.is(bindings.returnNull(), null);

  const symbol = bindings.createSymbol("foo");
  t.is(typeof symbol, "symbol");
  t.is(symbol.description, "foo");

  const obj = {};
  t.is(bindings.setSymbolInObj(obj), obj);
  const symbols = Object.getOwnPropertySymbols(obj);
  t.is(symbols.length, 1);
  t.is(symbols[0].description, "native");
  t.is(obj[symbols[0]], "symbol-value");
});

test("Result", (t) => {
  t.throws(bindings.throwError);
  t.throws(bindings.throwTypeError, { instanceOf: TypeError });
  t.throws(bindings.throwRangeError, { instanceOf: RangeError });
});

test("buffer", (t) => {
  const buffer = Buffer.from("hello");
  t.deepEqual(bindings.getBuffer(), Buffer.from("hello world"));
  t.is(bindings.getEmptyBuffer().length, 0);
  t.deepEqual(bindings.appendBuffer(buffer), Buffer.from("hello world"));
  t.is(bindings.bufferPassThrough(buffer), buffer);
  t.deepEqual(bindings.getBufferSlice(Buffer.from("abcdef"), 1, 4), Buffer.from("bcd"));
  t.deepEqual(bindings.createExternalBufferSlice(), Buffer.from("external"));
  t.deepEqual(bindings.createBufferSliceFromCopiedData(), Buffer.from("copied"));
});

test("ArrayBuffer", (t) => {
  const buffer = new ArrayBuffer(4);
  t.is(bindings.createArraybuffer(8).byteLength, 8);
  t.is(bindings.acceptArraybuffer(buffer), 4);
  t.is(bindings.arrayBufferPassThrough(buffer), buffer);

  const mutable = new Uint8Array([1, 2, 3]).buffer;
  bindings.mutateArraybuffer(mutable);
  t.deepEqual(Array.from(new Uint8Array(mutable)), [2, 3, 4]);

  t.deepEqual(Array.from(new Uint8Array(bindings.arrayBufferFromData())), [1, 2, 3, 4]);
  t.deepEqual(Array.from(new Uint8Array(bindings.arrayBufferFromExternal())), [5, 6, 7, 8]);
});

test("TypedArray", (t) => {
  t.true(bindings.getEmptyTypedArray() instanceof Uint8Array);
  t.is(bindings.getEmptyTypedArray().length, 0);

  t.deepEqual(bindings.u8ArrayToArray(new Uint8Array([1, 2, 3])), [1, 2, 3]);
  t.deepEqual(bindings.i8ArrayToArray(new Int8Array([-1, 2])), [-1, 2]);
  t.deepEqual(bindings.u16ArrayToArray(new Uint16Array([1, 2])), [1, 2]);
  t.deepEqual(bindings.i16ArrayToArray(new Int16Array([-1, 2])), [-1, 2]);
  t.deepEqual(bindings.u32ArrayToArray(new Uint32Array([1, 2])), [1, 2]);
  t.deepEqual(bindings.i32ArrayToArray(new Int32Array([-1, 2])), [-1, 2]);
  t.deepEqual(bindings.f32ArrayToArray(new Float32Array([1.5, 2.5])), [1.5, 2.5]);
  t.deepEqual(bindings.f64ArrayToArray(new Float64Array([1.5, 2.5])), [1.5, 2.5]);
  t.deepEqual(bindings.i64ArrayToArray(new BigInt64Array([1n, -2n])), [1, -2]);
  t.deepEqual(bindings.u64ArrayToArray(new BigUint64Array([1n, 2n])), [1, 2]);

  t.is(bindings.acceptSlice(new Int32Array([1, 2, 3])), 6);
  t.is(bindings.acceptUint8ClampedSlice(new Uint8ClampedArray([1, 2, 3])), 6);
  t.deepEqual(Array.from(bindings.convertU32Array(new Uint32Array([3, 4]))), [3, 4]);
  t.deepEqual(Array.from(bindings.createExternalTypedArray()), [1, 2, 3]);
  t.deepEqual(Array.from(bindings.createUint8ClampedArrayFromData()), [1, 2, 255]);
  t.deepEqual(Array.from(bindings.uint8ArrayFromData()), [1, 2, 3, 4]);
  t.deepEqual(Array.from(bindings.uint8ArrayFromExternal()), [5, 6, 7, 8]);

  const mutable = new Uint8Array([1, 2, 3]);
  bindings.mutateTypedArray(mutable);
  t.deepEqual(Array.from(mutable), [2, 3, 4]);
});

test("DataView", (t) => {
  const created = bindings.createDataView();
  t.true(created instanceof DataView);
  t.is(bindings.readDataView(created), 0x1234);

  const view = new DataView(new ArrayBuffer(4));
  bindings.mutateDataView(view);
  t.is(view.getUint16(0, true), 0x1234);
});

test("async", async (t) => {
  t.is(await bindings.asyncPlus100(23), 123);
  t.is(await bindings.asyncTaskOptionalReturn(true), 42);
  t.is(await bindings.asyncTaskOptionalReturn(false), undefined);
  t.deepEqual(await bindings.asyncResolveArray(4), [0, 1, 2, 3]);
});

const BigIntTest = typeof BigInt !== "undefined" ? test : test.skip;

BigIntTest("bigint", (t) => {
  t.is(bindings.createBigInt(), -3689348814741910323300n);
  t.is(bindings.createBigIntI64(), 100n);
  t.is(bindings.bigintAdd(20n, 22n), 42n);
  t.is(bindings.bigintGetU64AsString(0n), "0");
  t.is(bindings.bigintFromI64(), 100n);
  t.is(bindings.bigintFromI128(), -100n);
});

test("either", (t) => {
  t.is(bindings.eitherStringOrNumber(1), 101);
  t.is(bindings.eitherStringOrNumber("napi"), "napi");
  t.is(bindings.returnEither(true), "napi");
  t.is(bindings.returnEither(false), 42);
  t.is(bindings.eitherFromOption("zig"), "zig");
  t.is(bindings.eitherFromOption(null), 0);
});
