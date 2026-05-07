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
            assertIncludes(String(err && (err.message || err)), "TSFN Error", "thread safe function error callback");
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
  await waitForThreadSafeFunction(native);
}
