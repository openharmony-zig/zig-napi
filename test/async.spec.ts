import { assertArrayEqual, assertEqual, assertRejects } from "./assert";

type NativeAddon = ESObject;

function abortSignal(aborted: boolean): ESObject {
  return {
    aborted,
    reason: "test abort",
    onabort: null,
    addEventListener(_: string, __: ESObject) {},
    removeEventListener(_: string, __: ESObject) {},
    throwIfAborted() {
      if (aborted) {
        throw new Error("test abort");
      }
    },
  };
}

export async function testAsync(native: NativeAddon) {
  assertEqual(await native.fib_async(10), 55, "fib_async");

  const progressEvents: Array<ESObject> = [];
  assertEqual(await native.fib_async_progress(8, (event: ESObject) => progressEvents.push(event)), 21, "fib_async_progress");
  assertEqual(progressEvents.length, 2, "fib_async_progress events");
  assertEqual(progressEvents[0].current, 0, "fib_async_progress first event");
  assertEqual(progressEvents[1].current, 8, "fib_async_progress last event");

  const firstText = "alpha\n";
  const secondText = "bravo\n";
  assertEqual(await native.read_file_async("fixtures/first.txt"), firstText, "read_file_async");

  const summary = await native.read_file_summary_async("fixtures/first.txt");
  assertEqual(summary.path, "fixtures/first.txt", "read_file_summary path");
  assertEqual(summary.bytes, firstText.length, "read_file_summary bytes");
  assertEqual(summary.text, firstText, "read_file_summary text");

  const parallel = await native.parallel_read_files_async({
    first_path: "fixtures/first.txt",
    second_path: "fixtures/second.txt",
    preview_bytes: 3,
  });
  assertEqual(parallel.first_bytes, firstText.length, "parallel first bytes");
  assertEqual(parallel.second_bytes, secondText.length, "parallel second bytes");
  assertEqual(parallel.total_bytes, firstText.length + secondText.length, "parallel total bytes");
  assertEqual(parallel.preview, "alp\n---\nbra", "parallel preview");

  const math = await native.async_math_single({ left: 3, right: 4, scale: 2 });
  assertEqual(math.sum, 7, "async math sum");
  assertEqual(math.product, 12, "async math product");
  assertEqual(math.scaled_sum, 14, "async math scaled_sum");

  await native.async_void_thread();
  await assertRejects(native.async_fail_thread("async boom"), "async boom", "async_fail_thread");

  const countEvents: Array<ESObject> = [];
  assertEqual(await native.count_async_progress_thread(3, (event: ESObject) => countEvents.push(event)), 3, "count_async_progress_thread result");
  assertArrayEqual(countEvents.map((event: ESObject) => event.current), [0, 1, 2, 3], "count_async_progress_thread current events");

  const eventModeEvents: Array<ESObject> = [];
  assertEqual(await native.event_mode_progress_async(2, (event: ESObject) => eventModeEvents.push(event)), 2, "event_mode_progress_async result");
  assertArrayEqual(eventModeEvents.map((event: ESObject) => event.current), [0, 1, 2], "event_mode_progress_async current events");

  await assertRejects(native.abortable_count_async(4096, abortSignal(true)), "AbortError", "abortable_count_async pre-aborted");
}
