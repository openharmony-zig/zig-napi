const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 8 ? ava : ava.skip;

test("should be able to freeze object", (t) => {
  const object = { value: 1 };
  t.is(bindings.freezeObject(object), object);
  t.true(Object.isFrozen(object));
});

test("should be able to seal object", (t) => {
  const object = { value: 1 };
  t.is(bindings.sealObject(object), object);
  t.true(Object.isSealed(object));
});
