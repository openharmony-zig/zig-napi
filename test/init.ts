import { assertArrayEqual, assertEqual, assertThrows } from "./assert";
import { runSuite } from "./native";

runSuite("__ZIG_NAPI_INIT_TEST_RESULT__", async (native) => {
  assertEqual(native.add(19, 23), 42, "init add");
  assertEqual(native.test_i32(1, 2), 3, "init test_i32");
  assertEqual(native.test_f32(1.25, 2.5), 3.75, "init test_f32");
  assertEqual(native.test_u32(4, 5), 9, "init test_u32");
  assertEqual(native.hello("ArkTS"), "Hello, ArkTS!", "init hello");
  assertEqual(native.text, "Hello", "init text");

  native.fib(1);
  assertEqual(await native.fib_async(10), 55, "init fib_async");

  assertArrayEqual(native.get_and_return_array([1, 2, 3]), [1, 2, 3], "init array roundtrip");
  assertArrayEqual(native.get_arraylist([3, 2, 1]), [3, 2, 1], "init arraylist roundtrip");
  assertArrayEqual(
    native.get_named_array([7, true, "tuple"]),
    [7, true, "tuple"],
    "init tuple roundtrip",
  );

  assertThrows(() => native.throw_error(), "test", "init throw_error");
});
