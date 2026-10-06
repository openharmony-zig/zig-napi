import { assert } from "./assert";
const arkGlobal = globalThis as ESObject;
const KEEP_ALIVE_INTERVAL_MS = 10;

export function delay(ms: number) {
  return new Promise<void>((resolve) => {
    // ArkVM's interop timers can repeatedly execute a zero-delay interval
    // before libuv gets to drain native finalizers. Use a real timer gap for
    // cleanup polling too; GC alone does not execute those queued callbacks.
    const timer = setInterval(
      () => {
        clearInterval(timer);
        resolve();
      },
      Math.max(ms, KEEP_ALIVE_INTERVAL_MS),
    );
  });
}

function forceGc() {
  const tools = arkGlobal.ArkTools;
  if (!tools) {
    return;
  }
  // Hints may be ignored below ArkVM's heap-pressure thresholds. This suite
  // checks native ownership after JS collection, so request an actual full GC.
  if (typeof tools.forceFullGC === "function") {
    tools.forceFullGC();
    return;
  }
  if (tools.hintGC) {
    tools.hintGC();
  }
  if (tools.hintOldSpaceGC) {
    tools.hintOldSpaceGC();
  }
}

export async function settleFinalizers(rounds = 8) {
  for (let i = 0; i < rounds; i++) {
    const pressure: Array<ArrayBuffer> = [];
    for (let j = 0; j < 16; j++) {
      pressure.push(new ArrayBuffer(64 * 1024));
    }
    pressure.length = 0;
    forceGc();
    await delay(0);
  }
}

export async function withLeakTracking(
  native: NativeAddon,
  label: string,
  run: () => Promise<void> | void,
) {
  let tracking = false;
  native.leak_tracker_start();
  tracking = true;
  try {
    await run();
    await settleFinalizers(4);
    const deadline = Date.now() + 5000;
    while (native.leak_tracker_live_bytes() !== 0 && Date.now() < deadline) {
      await settleFinalizers(1);
    }
    const noLeaks = native.leak_tracker_finish();
    tracking = false;
    assert(noLeaks, `${label}: native global allocator leaked`);
  } catch (err) {
    if (tracking) {
      native.leak_tracker_abort();
    }
    throw err;
  }
}
