const path = require("path");
const { Worker } = require("worker_threads");
const test = require("ava");

test("should be able to require in worker thread", async (t) => {
  const worker = new Worker(path.join(__dirname, "worker.js"));
  const message = await new Promise((resolve, reject) => {
    worker.once("message", resolve);
    worker.once("error", reject);
  });

  t.is(message.sum, 42);
  t.is(`${message.napiVersion}`, process.versions.napi);
});
