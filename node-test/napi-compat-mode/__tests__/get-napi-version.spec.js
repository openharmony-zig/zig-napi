const test = require("ava");
const bindings = require("./binding");

test("should get napi version", (t) => {
  const napiVersion = bindings.getNapiVersion();
  t.is(typeof napiVersion, "number");
  t.is(`${napiVersion}`, process.versions.napi);
});
