const { parentPort } = require("worker_threads");
const bindings = require("./binding");

parentPort.postMessage({
  sum: bindings.add(20, 22),
  napiVersion: bindings.getNapiVersion(),
});
