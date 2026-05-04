declare function requireNapiPreview(name: string, isApp: boolean): ESObject;
declare function print(message: string): void;

type NativeAddon = ESObject;

function fail(message: string): never {
  throw new Error(message);
}

function assert(condition: boolean, message: string) {
  if (!condition) {
    fail(message);
  }
}

function assertEqual(actual: ESObject, expected: ESObject, message: string) {
  if (actual !== expected) {
    fail(`${message}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

function assertArrayEqual(actual: Array<ESObject>, expected: Array<ESObject>, message: string) {
  assertEqual(actual.length, expected.length, `${message}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${message}[${i}]`);
  }
}

async function run() {
  const native = requireNapiPreview("hello", true) as NativeAddon;

  assertEqual(native.test_i32(1, 2), 3, "test_i32");
  assertEqual(native.test_u32(4, 5), 9, "test_u32");
  assertEqual(native.hello("ArkTS"), "Hello, ArkTS!", "hello");
  assertEqual(native.text, "Hello World", "const text");

  assertArrayEqual(native.get_and_return_array([1, 2, 3]), [1, 2, 3], "array roundtrip");
  assertArrayEqual(native.get_named_array([7, true, "tuple"]), [7, true, "tuple"], "tuple roundtrip");

  const objectResult = native.get_object({
    name: "Ada",
    age: 36,
    is_student: false,
  });
  assertEqual(objectResult.name, "Ada", "object.name");
  assertEqual(objectResult.age, 36, "object.age");
  assertEqual(objectResult.is_student, false, "object.is_student");

  assertEqual(native.union_kind(42), "number", "union number");
  assertEqual(native.union_kind("forty-two"), "text", "union text");
  assertEqual(await native.fib_async(10), 55, "fib_async");

  native.leak_tracker_start();
  for (let i = 0; i < 1000; i++) {
    native.hello(`ArkTS-${i}`);
    native.get_object({
      name: `name-${i}`,
      age: i,
      is_student: i % 2 === 0,
    });
    native.get_named_array([i, i % 2 === 0, `tuple-${i}`]);
    native.union_kind(`variant-${i}`);
  }
  assert(native.leak_tracker_finish(), "native temporary allocator leaked");
}

run()
  .then(() => {
    print("__ZIG_NAPI_TEST_RESULT__ status=ok");
  })
  .catch((err: ESObject) => {
    const message = String(err && (err.message || err));
    print(`__ZIG_NAPI_TEST_RESULT__ status=fail message=${message}`);
    throw err;
  });
