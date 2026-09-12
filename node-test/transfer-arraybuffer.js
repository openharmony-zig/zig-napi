const { MessageChannel } = require("worker_threads");

// Transfer detaches synchronously on Node 12+, including versions that do not
// expose structuredClone. The receiving clone is deliberately discarded.
module.exports = function detachArrayBuffer(buffer) {
  const { port1, port2 } = new MessageChannel();
  try {
    port1.postMessage(buffer, [buffer]);
  } finally {
    port1.close();
    port2.close();
  }
};
