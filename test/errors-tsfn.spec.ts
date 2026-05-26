import { assert, assertEqual, assertIncludes, assertThrows } from "./assert";

type NativeAddon = ESObject;

async function waitForThreadSafeFunction(native: NativeAddon) {
  await new Promise<void>((resolve, reject) => {
    let sawOk = false;
    let sawErr = false;

    function maybeResolve() {
      if (sawOk && sawErr) {
        resolve();
      }
    }

    try {
      native.call_thread_safe_function((err: ESObject, left: number, right: number) => {
        try {
          if (err) {
            assert(!sawErr, "thread safe function error callback duplicated");
            assertIncludes(
              String(err && (err.message || err)),
              "TSFN Error",
              "thread safe function error callback",
            );
            sawErr = true;
          } else {
            assert(!sawOk, "thread safe function success callback duplicated");
            assertEqual(left + right, 3, "thread safe function success callback");
            sawOk = true;
          }
          maybeResolve();
        } catch (callbackErr) {
          reject(callbackErr);
        }
      });
    } catch (err) {
      reject(err);
    }
  });
}

export async function testErrorsAndThreadSafeFunction(native: NativeAddon) {
  assertThrows(() => native.throw_error(), "test", "throw_error repeat");
  assertThrows(() => native.throw_zig_error(), "ZigNativeFailure", "throw_zig_error");
  assertEqual(native.result_ok(), 42, "result_ok");
  assertThrows(() => native.result_error(), "result error", "result_error");
  assertEqual(native.result_void_ok(), undefined, "result_void_ok");
  assertEqual(native.result_after_try(true), 100, "result_after_try ok");
  assertThrows(() => native.result_after_try(false), "result type error", "result_after_try error");
  assertThrows(() => native.throw_zig_error_value(), "ZigValueFailure", "throw_zig_error_value");
  await waitForThreadSafeFunction(native);
}
