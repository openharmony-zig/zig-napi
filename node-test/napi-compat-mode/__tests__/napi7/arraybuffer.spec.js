const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 7 ? ava : ava.skip;

test("should be able to detach ArrayBuffer", (t) => {
  const buf = Buffer.from("hello world");
  const ab = buf.buffer.slice(0, buf.length);
  try {
    bindings.detachArrayBuffer(ab);
    t.is(ab.byteLength, 0);
  } catch (e) {
    t.is(e.code, "DetachableArraybufferExpected");
  }
});

test("is detached arraybuffer should work fine", (t) => {
  const buf = Buffer.from("hello world");
  const ab = buf.buffer.slice(0, buf.length);
  try {
    bindings.detachArrayBuffer(ab);
    const nonDetachedArrayBuffer = new ArrayBuffer(10);
    t.true(bindings.isDetachedArrayBuffer(ab));
    t.false(bindings.isDetachedArrayBuffer(nonDetachedArrayBuffer));
  } catch (e) {
    t.is(e.code, "DetachableArraybufferExpected");
  }
});
