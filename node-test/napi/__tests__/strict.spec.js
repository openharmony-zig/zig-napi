const test = require("ava");
const bindings = require("./binding");

test("should validate array", (t) => {
  t.is(bindings.validateArray([1, 2, 3]), 3);
  t.throws(() => bindings.validateArray(1));
});

test("should validate arraybuffer", (t) => {
  t.is(bindings.validateTypedArray(new Uint8Array([1, 2, 3])), 3);
  t.throws(() => bindings.validateTypedArray(1));
});

test("should validate BigInt", (t) => {
  const fx = 1024n;
  t.is(bindings.validateBigint(fx), fx);
  t.throws(() => bindings.validateBigint(1));
});

test("should validate buffer", (t) => {
  t.is(bindings.validateBuffer(Buffer.from("hello")), 5);
  t.throws(() => bindings.validateBuffer(2));
});

test("should validate boolean value", (t) => {
  t.is(bindings.validateBoolean(true), false);
  t.is(bindings.validateBoolean(false), true);
  t.throws(() => bindings.validateBoolean(1));
});

test("should validate function", (t) => {
  t.is(
    bindings.validateFunction(() => 4),
    4,
  );
  t.throws(() => bindings.validateFunction(2));
});

test("should validate string", (t) => {
  t.is(bindings.validateString("hello"), "hello!");
  t.throws(() => bindings.validateString(1));
});

test("should validate null", (t) => {
  t.notThrows(() => bindings.validateNull(null));
  t.throws(() => bindings.validateNull(1));
});

test("should validate undefined", (t) => {
  t.notThrows(() => bindings.validateUndefined(undefined));
  t.throws(() => bindings.validateUndefined(1));
});

test("should validate enum", (t) => {
  t.is(bindings.validateEnum(bindings.KindInValidate.Cat), bindings.KindInValidate.Cat);
  t.throws(() => bindings.validateEnum("3"));
  t.is(bindings.validateStringEnum(bindings.StatusInValidate.Poll), "Poll");
  t.throws(() => bindings.validateStringEnum(1));
});

test("should validate Option<T>", (t) => {
  t.is(bindings.validateOptional(null, null), false);
  t.is(bindings.validateOptional(null, false), false);
  t.is(bindings.validateOptional("1", false), true);
  t.is(bindings.validateOptional(null, true), true);
});
