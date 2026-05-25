const ava = require("ava");
const bindings = require("../binding");
const { napiVersion } = require("../napi-version");

const test = napiVersion >= 4 ? ava : ava.skip;

test("should get js function called from a thread", async (t) => {
  await new Promise((resolve, reject) => {
    bindings.callThreadsafeFunction((err, left, right) => {
      try {
        t.is(err, null);
        t.is(left + right, 3);
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  });
});
