const test = require("ava");
const bindings = require("./binding");

test("Function message", (t) => {
  const error = t.throws(bindings.throwError);
  t.regex(error.message, /native error/);
});
