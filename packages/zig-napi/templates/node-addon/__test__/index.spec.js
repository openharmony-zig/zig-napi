const test = require("ava");
const addon = require("../index");

test("exports addon functions", (t) => {
  t.is(addon.add(20, 22), 42);
  t.is(addon.hello(), "hello from __PACKAGE_NAME__");
});
