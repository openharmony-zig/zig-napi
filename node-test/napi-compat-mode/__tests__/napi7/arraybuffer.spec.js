const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 7 ? ava : ava.skip;

test("should be able to detach ArrayBuffer", (t) => {
  const buffer = new ArrayBuffer(8);
  bindings.detachArrayBuffer(buffer);
  t.is(buffer.byteLength, 0);
});

test("is detached arraybuffer should work fine", (t) => {
  const buffer = new ArrayBuffer(8);
  t.false(bindings.isDetachedArrayBuffer(buffer));
  bindings.detachArrayBuffer(buffer);
  t.true(bindings.isDetachedArrayBuffer(buffer));
});
