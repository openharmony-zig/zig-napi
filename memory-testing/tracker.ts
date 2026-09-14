import { assert, assertEqual, assertThrows } from "./assert";
import { settleFinalizers } from "./native";

export async function exerciseLeakTrackerLifecycle(native: ESObject) {
  native.leak_tracker_start();
  let retained: ESObject = native.manual_resolved_promise();
  assertThrows(() => native.leak_tracker_start(), "reject nested tracking");
  native.leak_tracker_abort();

  // Aborting restores the operation allocator, but the retained Promise still
  // owns its capability through the old allocator. A new scope must not erase it.
  assert(native.leak_tracker_live_bytes() > 0, "retained promise must be tracked");
  assertThrows(() => native.leak_tracker_start(), "reject restart with live owners");
  assertEqual(await retained, 42, "retained promise remains valid after abort");
  retained = null;

  const deadline = Date.now() + 5000;
  while (native.leak_tracker_live_bytes() !== 0 && Date.now() < deadline) {
    await settleFinalizers(1);
  }
  assertEqual(native.leak_tracker_live_bytes(), 0, "late finalizer releases aborted scope");
  native.leak_tracker_start();
  assert(native.tracked_alloc_roundtrip(64), "tracker reusable after late finalizer");
  assert(native.leak_tracker_finish(), "restarted tracker must be empty");
}
