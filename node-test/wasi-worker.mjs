import fs from "node:fs";
import { createRequire } from "node:module";
import { parse } from "node:path";
import { WASI } from "node:wasi";
import { parentPort, Worker, workerData } from "node:worker_threads";

const require = createRequire(import.meta.url);

const {
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
  getDefaultContext,
  instantiateNapiModuleSync,
  MessageHandler,
} = require("@napi-rs/wasm-runtime");

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

globalThis.onmessage = function (event) {
  handler.handle(event);
};
