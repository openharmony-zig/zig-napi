const assert = require("assert").strict;
const addon = require("./index");

async function main() {
  assert.equal(addon.add(20, 22), 42);
  assert.equal(addon.hello(), "hello from node");
  assert.equal(addon.requestedNapiVersion(), 8);
  assert.equal(await addon.fibonacciAsync(10), 55);

  const box = new addon.SymbolBox(2);
  assert.equal(Object.prototype.toString.call(box), "[object SymbolBox]");
  box[Symbol.for("pair")] = 7;
  assert.equal(box[Symbol.for("pair")], 7);
  assert.equal(box[Symbol.for("zig-napi.value")], 7);
  assert.equal(box.value, undefined);

  const events = [];
  assert.equal(
    await addon.countAsyncProgress(3, (event) => {
      events.push(event);
    }),
    3,
  );
  assert.deepEqual(events, [
    { current: 0, total: 3 },
    { current: 3, total: 3 },
  ]);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
