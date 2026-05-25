const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 6 ? ava : ava.skip;

test("should create bigints", (t) => {
  t.is(bindings.createBigInt(), 9007199254740993n);
  t.is(bindings.bigintAdd(20n, 22n), 42n);
});

test("should get integers from bigints", (t) => {
  t.is(bindings.bigintToI64(42n), 42);
});

test("should be able to mutate BigInt64Array", (t) => {
  const fixture = new BigInt64Array([0n, 1n, 2n]);
  bindings.mutateI64Array(fixture);
  t.deepEqual(fixture[0], 9223372036854775807n);
});
