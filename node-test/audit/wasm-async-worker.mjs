// Worker side of the threaded WASI flavor, for `wasm-async-lifecycle.spec.js`.
//
// Same shape as the generated `wasi-worker.mjs`, with the emnapi 2 plugins that
// every thread instantiating an emnapi 2 archive needs. Kept next to the spec so
// the async lifecycle tests do not depend on the generated loader files.
import fs from "node:fs";
import { createRequire } from "node:module";
import { parse } from "node:path";
import { WASI } from "node:wasi";
import { parentPort, Worker } from "node:worker_threads";

const require = createRequire(import.meta.url);

const {
  instantiateNapiModuleSync,
  MessageHandler,
  getDefaultContext,
  emnapiAsyncWorkPlugin,
  emnapiTSFNPlugin,
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
    // eslint-disable-next-line no-eval
    (0, eval)(fs.readFileSync(f, "utf8") + "//# sourceURL=" + f);
  },
  postMessage(msg) {
    if (parentPort) {
      parentPort.postMessage(msg);
    }
  },
});

const emnapiContext = getDefaultContext();
const rootDir = parse(process.cwd()).root;

const handler = new MessageHandler({
  onLoad({ wasmModule, wasmMemory }) {
    const wasi = new WASI({
      version: "preview1",
      env: process.env,
      preopens: {
        [rootDir]: rootDir,
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
      },
    });
  },
});

globalThis.onmessage = function (event) {
  handler.handle(event);
};
