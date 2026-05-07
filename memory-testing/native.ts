import { assert } from "./assert";

declare function requireNapiPreview(name: string, isApp: boolean): ESObject;
declare function print(message: string): void;
declare function setInterval(callback: () => void, delay: number): number;
declare function clearInterval(id: number): void;
declare const globalThis: ESObject;

type NativeAddon = ESObject;

const SUITE_TIMEOUT_MS = 120000;
const KEEP_ALIVE_INTERVAL_MS = 10;

export function installTimerGlobals() {
  const etsInterop = requireNapiPreview("ets_interop_js_napi", true) as ESObject;
  const created = etsInterop.createRuntime({
    "panda-files": "./hello.abc",
    "boot-panda-files": "./etsstdlib.abc:./hello.abc",
    "xgc-trigger-type": "never",
  });
  if (!created) {
    throw new Error("failed to initialize ArkVM timer runtime");
  }
}

export function loadNative(): NativeAddon {
  return requireNapiPreview("hello", true) as NativeAddon;
}

export function delay(ms: number) {
  return new Promise<void>((resolve) => {
    const timer = setInterval(() => {
      clearInterval(timer);
      resolve();
    }, ms);
  });
}

function forceGc() {
  const tools = globalThis.ArkTools;
  if (!tools) {
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

function failResult(resultPrefix: string, err: ESObject): never {
  const message = String(err && (err.message || err));
  print(`${resultPrefix} status=fail message=${message}`);
  throw err;
}

export function runMemorySuite(
  resultPrefix: string,
  run: (native: NativeAddon) => Promise<void> | void,
) {
  installTimerGlobals();

  let finished = false;
  let elapsed = 0;
  const keepAlive = setInterval(() => {
    if (finished) {
      clearInterval(keepAlive);
      return;
    }
    elapsed += KEEP_ALIVE_INTERVAL_MS;
    if (elapsed >= SUITE_TIMEOUT_MS) {
      finished = true;
      clearInterval(keepAlive);
      failResult(resultPrefix, new Error(`suite timed out after ${SUITE_TIMEOUT_MS}ms`));
    }
  }, KEEP_ALIVE_INTERVAL_MS);

  Promise.resolve()
    .then(() => run(loadNative()))
    .then(
      () => {
        if (finished) {
          return;
        }
        finished = true;
        print(`${resultPrefix} status=ok`);
        clearInterval(keepAlive);
      },
      (err) => {
        if (finished) {
          return;
        }
        finished = true;
        clearInterval(keepAlive);
        failResult(resultPrefix, err);
      },
    );
}
