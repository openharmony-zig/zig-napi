import { assertApproxEqual, assertEqual, assertThrows } from "./assert";

type NativeAddon = ESObject;

export function testPrimitives(native: NativeAddon) {
  assertEqual(native.test_i32(1, 2), 3, "test_i32 positive");
  assertEqual(native.test_i32(-7, 2), -5, "test_i32 negative");
  assertEqual(native.test_u32(4, 5), 9, "test_u32");
  assertApproxEqual(native.test_f32(1.25, 2.5), 3.75, "test_f32");

  assertEqual(native.hello("ArkTS"), "Hello, ArkTS!", "hello");
  assertEqual(native.hello(""), "Hello, !", "hello empty");
  assertEqual(native.text, "Hello World", "const text");

  assertThrows(() => native.throw_error(), "test", "throw_error");
  native.test_hilog();
  native.fib(1);
}
