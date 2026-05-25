const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 4 ? ava : ava.skip;

test("should resolve deferred from background thread", async (t) => {
  t.is(await bindings.doubleAsync(21), 42);
});
