const test = require("ava");
const bindings = require("./binding");

test("should be able to throw error from native", (t) => {
  t.throws(bindings.testThrow);
});

test("should be able to throw error from native with reason", (t) => {
  const reason = "Fatal";
  const error = t.throws(() => bindings.testThrowWithReason(reason));
  t.regex(error.message, /Fatal/);
});

test("should throw if Rust code panic", (t) => {
  t.throws(() => bindings.testThrowWithPanic());
});
