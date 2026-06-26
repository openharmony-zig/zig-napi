const assert = require("assert").strict;
const addon = require("./index");

async function main() {
  assert.equal(addon.add(20, 22), 42);
  assert.equal(addon.hello(), "hello from node");
  assert.equal(addon.requestedNapiVersion(), 8);
  assert.equal(await addon.fibonacciAsync(10), 55);

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
