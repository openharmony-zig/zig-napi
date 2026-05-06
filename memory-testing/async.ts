import { assert, assertArrayEqual, assertEqual, assertRejects } from "./assert";
import { delay, settleFinalizers } from "./native";

type NativeAddon = ESObject;

type AbortControllerLike = {
  signal: ESObject;
  abort: () => void;
};

function abortController(aborted: boolean): AbortControllerLike {
  const signal: ESObject = {
    aborted,
    reason: "memory abort",
    onabort: null,
    addEventListener(_: string, __: ESObject) {},
    removeEventListener(_: string, __: ESObject) {},
    throwIfAborted() {
      if (this.aborted) {
        throw new Error("memory abort");
      }
    },
  };
  return {
    signal,
    abort() {
      signal.aborted = true;
      if (signal.onabort) {
        signal.onabort();
      }
    },
  };
}

export async function exerciseThreadSafeFunctionWrapper(native: NativeAddon) {
  await new Promise<void>((resolve, reject) => {
    let sawOk = false;
    let sawErr = false;

    function maybeResolve() {
      if (sawOk && sawErr) {
        resolve();
      }
    }

    try {
      native.memory_thread_safe_function((err: ESObject, left: number, right: number) => {
        try {
          if (err) {
            assert(!sawErr, "tsfn error callback duplicated");
            sawErr = true;
          } else {
            assert(!sawOk, "tsfn success callback duplicated");
            assertEqual(left + right, 3, "tsfn callback");
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
  await settleFinalizers(8);
}

export async function exerciseAsyncWrappers(native: NativeAddon) {
  const summary = await native.memory_async_summary({
    label: "async-summary",
    values: [1, 2, 3, 4],
  });
  assertEqual(summary.label, "async-summary", "async summary label");
  assertEqual(summary.count, 4, "async summary count");
  assertEqual(summary.total, 10, "async summary total");

  const singleSummary = await native.memory_async_summary_single({
    label: "async-single",
    values: [2, 3, 5],
  });
  assertEqual(singleSummary.label, "async-single", "async single label");
  assertEqual(singleSummary.count, 3, "async single count");
  assertEqual(singleSummary.total, 10, "async single total");

  await native.memory_async_void("async-void");
  await assertRejects(native.memory_async_fail("async memory failure"), "async memory failure", "async fail");
  assertEqual(await native.manual_resolved_promise(), 42, "manual promise wrapper");

  const progressEvents: Array<ESObject> = [];
  assertEqual(await native.memory_async_progress(3, (event: ESObject) => progressEvents.push(event)), 3, "async progress result");
  assertArrayEqual(progressEvents.map((event: ESObject) => event.current), [0, 1, 2, 3], "async progress events");

  const eventModeEvents: Array<ESObject> = [];
  assertEqual(await native.memory_event_mode_progress(2, (event: ESObject) => eventModeEvents.push(event)), 2, "event progress result");
  assertArrayEqual(eventModeEvents.map((event: ESObject) => event.current), [0, 1, 2], "event progress events");

  await assertRejects(native.memory_abortable_count(1024, abortController(true).signal), "AbortError", "abort pre-cancel");

  const controller = abortController(false);
  const pending = native.memory_abortable_slow_count(100000, controller.signal);
  await delay(0);
  controller.abort();
  await assertRejects(pending, "AbortError", "abort mid-flight");

  assertEqual(await native.memory_worker(41), 42, "worker promise result");
}
