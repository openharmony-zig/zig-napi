const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 5 ? ava : ava.skip;

test("should return false if value is not date", (t) => {
  t.false(bindings.isDate(1));
});

test("should return true if value is date", (t) => {
  t.true(bindings.isDate(new Date()));
});

test("should create date", (t) => {
  const date = bindings.createDate(1000);
  t.true(date instanceof Date);
  t.is(date.valueOf(), 1000);
});

test("should get date value", (t) => {
  const date = new Date(1000);
  t.is(bindings.getDateValue(date), date.valueOf());
});
