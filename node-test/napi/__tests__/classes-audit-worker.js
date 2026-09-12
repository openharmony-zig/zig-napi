// Loads the audit addon inside a worker thread and exercises the class
// constructor references of that environment while the main thread keeps
// using its own.
const { parentPort } = require("worker_threads");

const audit = require("../../load-addon")("classes_audit");

parentPort.once("message", (id) => {
  parentPort.postMessage({
    id,
    constructed: new audit.WidgetClass(id).value,
    made: audit.WidgetClass.make(id * 100).value,
    static: audit.WidgetClass.twice(id),
    noInit: audit.NoInitClass.make(id).value,
  });
});
