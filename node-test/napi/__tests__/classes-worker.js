// Loads the classes addon inside a worker thread and exercises the class
// constructor references of that environment while the main thread keeps
// using its own.
const { parentPort } = require("worker_threads");

const classes = require("../../load-addon")("classes");

parentPort.once("message", (id) => {
  parentPort.postMessage({
    id,
    constructed: new classes.WidgetClass(id).value,
    made: classes.WidgetClass.make(id * 100).value,
    static: classes.WidgetClass.twice(id),
    noInit: classes.NoInitClass.make(id).value,
  });
});
