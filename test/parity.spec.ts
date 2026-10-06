import { assert, assertEqual, assertThrows } from "./assert";

export async function testParity(native: ESObject) {
  const lengths = native.parityStringLengths("A😀\0é");
  assertEqual(lengths.utf8, 8, "UTF8 bytes");
  assertEqual(lengths.utf16, 5, "UTF16 code units");
  assertEqual(lengths.latin1, 5, "Latin1 code units");
  assertEqual(native.parityLatin1("\0éÿ"), "\0éÿ", "Latin1 roundtrip");
  let calls = 0;
  Object.defineProperty(Object.prototype, "x", {
    configurable: true,
    set() {
      calls++;
    },
  });
  let object: ESObject;
  try {
    object = native.parityObject();
  } finally {
    delete Object.prototype.x;
  }
  assertEqual(calls, 0, "inherited setter must not run");
  assertEqual(object.x, 42, "own data property");
  assert(Object.prototype.hasOwnProperty.call(object, "__proto__"), "own __proto__");
  assertEqual(Object.getPrototypeOf(object), Object.prototype, "prototype preserved");
  function add(value: number): number {
    return this.base + value;
  }
  assertEqual(native.parityApply(add, { base: 40 }, 2), 42, "apply receiver");
  assertEqual(native.parityBind(add, { base: 10 })(3), 13, "bound receiver");
  function Box(value: number) {
    this.value = value;
  }
  const box = native.parityConstruct(Box, 42);
  assert(box instanceof Box, "constructor prototype");
  assertEqual(box.value, 42, "constructor argument");
  assertEqual(native.parityTools.functionName(add), "add", "function name");
  const closure = native.parityClosure(10);
  assertEqual(closure(2), 12, "closure first call");
  assertEqual(closure(3), 15, "closure second call");
  assertThrows(() => closure("bad"), "Expected", "closure conversion failure");
  assertEqual(closure(1), 16, "closure state after conversion failure");
  assertEqual(native.parityScope(), "escaped", "escape handle scope");
  const reason = { sentinel: true };
  let caught: ESObject;
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
  assertEqual(caught, reason, "callback exception identity");
}

export async function testParityProtocols(native: ESObject) {
  assertEqual(
    await native.parityAwaitPromise(new Promise((resolve) => setTimeout(() => resolve(21), 10))),
    42,
    "native worker awaits JS promise",
  );
  let nativeReject: ESObject;
  try {
    await native.parityAwaitPromise(Promise.reject(new Error("promise-native-rejection")));
  } catch (err) {
    nativeReject = err;
  }
  assert(
    String(nativeReject).includes("promise-native-rejection"),
    "native promise rejection reaches caller",
  );
  assertEqual(
    await native.parityPromise(Promise.resolve(21), (value: number) => value * 2),
    42,
    "typed promise then",
  );
  const reason = { sentinel: 42 };
  let caught: ESObject;
  assertEqual(
    await native.parityPromiseCatch(Promise.reject(reason), (value: ESObject) => {
      caught = value;
      return 7;
    }),
    7,
    "promise catch",
  );
  assertEqual(caught, reason, "promise rejection identity");
  let finallyCalls = 0;
  assertEqual(
    await native.parityPromiseFinally(Promise.resolve(12), () => {
      finallyCalls++;
    }),
    12,
    "promise finally value",
  );
  assertEqual(finallyCalls, 1, "promise finally runs once");
  const mapping = native.parityMap({ first: "one", second: "two" });
  assertEqual(mapping.first, "one", "map value");
  assertThrows(() => native.parityMap({ first: 1 }), "Expected", "map conversion failure");
  const set = native.paritySet(new Set<number>([1, 2, 1]));
  assertEqual(set.size, 2, "set unique values");
  assert(set.has(1) && set.has(2), "set membership");
  const json = { text: "A😀\0", nil: null, bool: true, array: [1, { x: 2 }] };
  assertEqual(JSON.stringify(native.parityJson(json)), JSON.stringify(json), "recursive JSON");
  const capture = { key: "initial" };
  const pending = native.parityAsyncMap(capture);
  capture.key = "changed";
  assertEqual((await pending).key, "initial", "async map captures native copy");
  assertEqual(
    JSON.stringify(await native.parityAsyncJson(json)),
    JSON.stringify(json),
    "async JSON captures native copy",
  );
  const cyclic: ESObject = {};
  cyclic.self = cyclic;
  assertThrows(() => native.parityJson(cyclic), "cyclic", "cyclic JSON rejected");
  assertEqual(Array.from(native.parityIterator(3)).join(","), "0,1,2", "native iterator");
  assertEqual(native.parityIteratorSum([1, 2, 3][Symbol.iterator]()), 6, "JS iterator");
  assertEqual(
    native.parityIteratorSum({
      next() {
        return { done: true };
      },
    }),
    0,
    "done without value",
  );
  const asyncIterator = {
    next() {
      return Promise.resolve({ done: false, value: 7 });
    },
  };
  assertEqual((await native.parityAsyncIteratorNext(asyncIterator)).value, 7, "async iterator");
  const generator = native.parityAsyncGenerator(2);
  assertEqual(generator[Symbol.asyncIterator](), generator, "async generator identity");
  assertEqual((await generator.next()).value, 0, "async generator first value");
  assertEqual((await generator.next()).value, 1, "async generator second value");
  assert((await generator.next()).done, "async generator completes");
  const early = native.parityIterator(100);
  assertEqual(early.next().value, 0, "iterator before return");
  assert(early.return().done && early.next().done, "iterator remains closed");
  const closed = native.parityAsyncGenerator(100);
  assert(
    (await closed.return()).done && (await closed.next()).done,
    "async iterator remains closed",
  );
  const rejected = native.parityAsyncGenerator(100);
  let thrown: ESObject;
  try {
    await rejected.throw(reason);
  } catch (err) {
    thrown = err;
  }
  assertEqual(thrown, reason, "async iterator throw identity");
  assert((await rejected.next()).done, "throw closes iterator");
}

export async function testParityLifetimes(native: ESObject) {
  const environment = native.parityEnvironment();
  assert(
    environment.stored && environment.replacement_rejected && environment.async_removed,
    "environment ownership and cleanup hooks",
  );
  assertEqual(
    await native.parityTsfnAsync((value: number) => value * 2, 21),
    42,
    "TSFN return value",
  );
  const reason = { sentinel: true };
  let caught: ESObject;
  try {
    await native.parityTsfnAsync(() => {
      throw reason;
    }, 1);
  } catch (err) {
    caught = err;
  }
  assertEqual(caught, reason, "TSFN thrown value identity");
  assertEqual(
    await native.parityTsfnPromise((value: number) => Promise.resolve(value * 2), 21),
    42,
    "TSFN adopts promise",
  );
  const queues = native.parityTsfnBuilder((value: number) => value * 2);
  const rejected = queues.second.then(
    () => {
      throw new Error("queue-full must reject");
    },
    () => true,
  );
  assertEqual(await queues.first, 42, "weak TSFN builder return value");
  assertEqual(await rejected, true, "bounded TSFN queue rejects");
  const delivered: number[] = [];
  await new Promise<void>((resolve) => {
    native.parityTsfnBlocking((value: number) => {
      delivered.push(value);
      if (delivered.length === 3) resolve();
    });
  });
  assertEqual(delivered.join(","), "1,2,3", "bounded blocking producer resumes");
  assert(
    native.parityTsfnAbort(() => {}),
    "abort wakes native producer",
  );
  assertEqual(
    native.parityNamespaced(new native.parityTools.RenamedCounter(42)),
    42,
    "namespaced class export and instance",
  );
  assertEqual(
    native.parityFactoryInstance(native.ParityFactory.create(42)),
    42,
    "typed factory instance",
  );
  assertThrows(
    () => native.parityFactoryInstance(Object.create(native.ParityFactory.prototype)),
    "Expected",
    "factory prototype forgery rejected",
  );
  const instance = new native.ParityCounter(10);
  assertEqual(native.parityClassInstance(instance, 2), 12, "class instance parameter");
  assertEqual(instance.value, 12, "class state changed");
  assertThrows(() => native.parityClassInstance({}, 1), "Expected", "foreign instance rejected");
  assertThrows(
    () => native.parityClassInstance(Object.create(native.ParityCounter.prototype), 1),
    "Expected",
    "prototype forgery rejected",
  );
  assertEqual(native.parityShared(instance), instance, "shared and weak reference identity");
  assertEqual(
    native.paritySharedThread(instance),
    instance,
    "reference last owner released on native thread",
  );
  assert(!("MetadataSchema" in native.parityTools), "object schemas have no runtime constructor");
  const metadata = new native.MetadataCounter(10);
  assertEqual(metadata.count, 10, "renamed field");
  assert(!("value" in metadata) && !("secret" in metadata), "hidden original names");
  assertEqual(metadata.add(2), 12, "renamed method");
  assertEqual(metadata.double, 24, "computed getter");
  metadata.double = 40;
  assertEqual(metadata.count, 20, "computed setter");
  assert(!Reflect.set(metadata, "count", 99), "readonly field");
  for (let i = 0; i < 100; i++)
    assertEqual(native.parityShared(metadata), metadata, "reference clones release independently");
  assertEqual(native.parityDate(new Date(123456)).getTime(), 123456, "typed Date");
  assertThrows(
    () =>
      native.parityDate({
        getTime() {
          return 1;
        },
      }),
    "Expected",
    "Date brand validation",
  );
  assertEqual(
    native.parityExternalLatin1("A\0éÿ").value,
    "A\0éÿ",
    "external Latin1 copying fallback",
  );
  assertEqual(
    native.parityExternalUtf16("A😀\0é").value,
    "A😀\0é",
    "external UTF16 copying fallback",
  );
  assertEqual(
    native.paritySymbolFor("zig-napi.parity"),
    Symbol.for("zig-napi.parity"),
    "global Symbol registry",
  );
  const symbol = Symbol("same");
  assertEqual(native.paritySymbol(symbol).input, symbol, "Symbol identity");
  assertEqual(typeof native.paritySymbol(symbol).unique, "symbol", "new Symbol");
  assertEqual(native.parityThis.call({ base: 40 }, 2), 42, "injected callback receiver");
  const object = native.parityMetadataObject({ count: 42, missing: null });
  assertEqual(object.count, 42, "object field rename");
  assertEqual(object.missing, null, "nullable object field");
  assert(!("internal" in object), "skipped object field");
  assert(!Reflect.set(object, "count", 1), "readonly object field");
  assertEqual(
    native.parityTagged({ kind: "second", data: { count: 7 } }).kind,
    "second",
    "explicit union variant",
  );
  assertThrows(
    () => native.parityTagged({ kind: "unknown", data: 1 }),
    "discriminant",
    "unknown union discriminant",
  );
}

export async function testParityStreams(native: ESObject) {
  let locked = false;
  let index = 0;
  let cancelled: ESObject;
  const stream = {
    getReader() {
      assertEqual(this, stream, "getReader receiver");
      assert(!locked, "reader lock is exclusive");
      locked = true;
      return {
        read() {
          return Promise.resolve(index < 2 ? { done: false, value: index++ } : { done: true });
        },
        cancel(reason: ESObject) {
          cancelled = reason;
          return Promise.resolve();
        },
        releaseLock() {
          locked = false;
        },
      };
    },
  };
  const reader = native.parityReadable(stream);
  assertEqual((await native.parityRead(reader)).value, 0, "reader first chunk");
  assertEqual((await native.parityRead(reader)).value, 1, "reader second chunk");
  assert((await native.parityRead(reader)).done, "reader EOF");
  const reason = { sentinel: 42 };
  await native.parityReaderCancel(reader, reason);
  assertEqual(cancelled, reason, "reader cancellation reason identity");
  native.parityReaderRelease(reader);
  assert(!locked, "reader lock released");
  const values: number[] = [];
  let closed = false;
  let aborted: ESObject;
  let writerReleased = false;
  const output = {
    getWriter() {
      return {
        write(value: number) {
          values.push(value);
          return Promise.resolve();
        },
        close() {
          closed = true;
          return Promise.resolve();
        },
        abort(value: ESObject) {
          aborted = value;
          return Promise.resolve();
        },
        releaseLock() {
          writerReleased = true;
        },
      };
    },
  };
  const writer = native.parityWritable(output);
  await native.parityWrite(writer, 42);
  assertEqual(values[0], 42, "writer chunk");
  await native.parityWriterAbort(writer, reason);
  assertEqual(aborted, reason, "writer abort reason identity");
  await native.parityWriterClose(writer);
  assert(closed, "writer close");
  native.parityWriterRelease(writer);
  assert(writerReleased, "writer lock released");
  assertThrows(() => native.parityReadable({}), "Expected", "invalid stream rejected");
}
