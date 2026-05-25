const test = require("ava");
const bindings = require("./binding");

test("should call the function", (t) => {
  bindings.testCallFunction((arg1, arg2) => {
    t.is(`${arg1} ${arg2}`, "hello world");
  });
});

test("should call function with ref args", (t) => {
  bindings.testCallFunctionWithRefArguments((arg1, arg2) => {
    t.is(`${arg1} ${arg2}`, "hello world");
  });
});

test("should handle errors", (t) => {
  bindings.testCallFunctionError(
    () => {
      throw new Error("Testing");
    },
    (message) => {
      t.is(message, "Testing");
    },
  );
});

test("should be able to create function from closure", (t) => {
  t.is(bindings.testCreateFunctionFromClosure()(1), "arguments length: 1");
});
