declare function requireNapiPreview(name: string, isApp: boolean): ESObject;
declare function print(message: string): void;
declare function setInterval(callback: () => void, delay: number): number;
declare function clearInterval(id: number): void;

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

export { delay, settleFinalizers, withLeakTracking } from "./support";

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
