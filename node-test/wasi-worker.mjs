import fs from "node:fs";
import { createRequire } from "node:module";
import { parse } from "node:path";
import { WASI } from "node:wasi";
import { parentPort, threadId, Worker, workerData } from "node:worker_threads";

const require = createRequire(import.meta.url);

const {
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  getDefaultContext,
  instantiateNapiModuleSync,
  MessageHandler,
} = (() => {
  try { return require("@napi-rs/wasm-runtime"); }
  catch (error) { __raiseWasiThreadCrashFlags(error); throw error; }
})();

if (parentPort) {
  parentPort.on("message", (data) => {
    globalThis.onmessage({ data });
  });
}

Object.assign(globalThis, {
  self: globalThis,
  require,
  Worker,
  importScripts(f) {
    // oxlint-disable-next-line no-eval -- WASI importScripts polyfill
    (0, eval)(fs.readFileSync(f, "utf8") + "//# sourceURL=" + f);
  },
  postMessage(msg) {
    if (parentPort) {
      parentPort.postMessage(msg);
    }
  },
});

const __cwd = process.cwd();
const __rootDir =
  (workerData && typeof workerData.rootDir === "string" && workerData.rootDir) || parse(__cwd).root;
const __hostRoot =
  (workerData && typeof workerData.hostRoot === "string" && workerData.hostRoot) ||
  (process.platform === "android" ? __cwd : __rootDir);

function __captureEmnapiAutoDestroyListener() {
  const __process = globalThis.process;
  if (
    !__process ||
    typeof __process.prependListener !== "function" ||
    typeof __process.removeListener !== "function"
  ) {
    return;
  }
  let __autoDestroyListener;
  const __captureListener = (__event, __listener) => {
    if (__event === "beforeExit" && __autoDestroyListener === undefined) {
      __autoDestroyListener = __listener;
    }
  };
  try {
    // Run before existing newListener hooks so a hook that registers its own
    // beforeExit listener cannot be mistaken for emnapi's registration.
    __process.prependListener("newListener", __captureListener);
  } catch {
    return;
  }
  return () => {
    try {
      __process.removeListener("newListener", __captureListener);
    } catch {}
    if (__autoDestroyListener !== undefined) {
      try {
        __process.removeListener("beforeExit", __autoDestroyListener);
      } catch {}
    }
  };
}

const __finishAutoDestroyCapture = __captureEmnapiAutoDestroyListener();
let emnapiContext;
try {
  emnapiContext = getDefaultContext();
  emnapiContext.suppressDestroy();
} finally {
  __finishAutoDestroyCapture?.();
}

const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    const wasi = new WASI({
      version: "preview1",
      env: process.env,
      preopens: {
        [__rootDir]: __hostRoot,
        [__hostRoot]: __hostRoot,
      },
    });

    return instantiateNapiModuleSync(wasmModule, {
      childThread: true,
      wasi,
      context: emnapiContext,
      plugins: [emnapiAsyncWorkPlugin, emnapiTSFNPlugin],
      overwriteImports(importObject) {
        importObject.env = {
          ...importObject.env,
          ...importObject.napi,
          ...importObject.emnapi,
          memory: wasmMemory,
        };
        return importObject;
      },
    });
  },
});

function __raiseWasiThreadCrashFlags(error) {
  try {
    __writeCrashReport(workerData.crashReport, error)
  } catch {}
  try {
    Atomics.store(workerData.crashFlag, 0, 1)
  } catch {}
  const addonCrashFlag = workerData.addonCrashFlag
  if (!(addonCrashFlag instanceof Int32Array)) {
    return false
  }
  try {
    Atomics.store(addonCrashFlag, 0, 1)
    return true
  } catch {
    return false
  }
}

function __writeCrashReport(report, error) {
  if (!(report instanceof SharedArrayBuffer) || report.byteLength <= 12) {
    return
  }
  const header = new Int32Array(report, 0, 3)
  if (Atomics.compareExchange(header, 0, 0, 1) !== 0) {
    return
  }
  let length = 0
  try {
    const body = new Uint8Array(report, 12)
    const isObject =
      error !== null && (typeof error === 'object' || typeof error === 'function')
    const name = isObject && typeof error.name === 'string' ? error.name : 'Error'
    const message = isObject && typeof error.message === 'string'
      ? error.message
      : String(error)
    const stack = isObject && typeof error.stack === 'string' ? error.stack : undefined
    const encoder = new TextEncoder()
    let bytes = encoder.encode(JSON.stringify({ name, message, stack }))
    if (bytes.length > body.length) {
      bytes = encoder.encode(
        JSON.stringify({ name, message: message.slice(0, body.length >> 3) }),
      )
    }
    if (bytes.length <= body.length) {
      body.set(bytes)
      length = bytes.length
    }
    Atomics.store(header, 2, threadId)
  } finally {
    Atomics.store(header, 1, length)
    Atomics.store(header, 0, 2)
  }
}

const __beforeReportError = handler.beforeReportError;
handler.beforeReportError = function (...args) {
  if (!__raiseWasiThreadCrashFlags(args[0])) {
    try { this.instance?.exports?.napi_wasm_thread_crashed?.(); } catch {}
  }
  return __beforeReportError?.apply(this, args);
};
globalThis.onmessage = function (event) {
  handler.handle(event);
};
