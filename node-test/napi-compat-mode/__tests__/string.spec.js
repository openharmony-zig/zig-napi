const test = require("ava");
const bindings = require("./binding");

test("should be able to concat string", (t) => {
  const fixture = "JavaScript 🌳 你好 napi";
  t.is(bindings.concatString(fixture), "JavaScript 🌳 你好 napi + Rust 🦀 string!");
});

test("should be able to concat string with char \\0", (t) => {
  const fixture = "JavaScript \0 🌳 你好 \0 napi";
  t.is(bindings.concatString(fixture), "JavaScript \0 🌳 你好 \0 napi + Rust 🦀 string!");
});

test("should be able to concat utf16 string", (t) => {
  const fixture = "JavaScript 🌳 你好 napi";
  t.is(bindings.concatUTF16String(fixture), "JavaScript 🌳 你好 napi + Rust 🦀 string!");
});

test("should be able to concat latin1 string", (t) => {
  const fixture = "æ¶½¾DEL";
  t.is(bindings.concatLatin1String(fixture), "æ¶½¾DEL + Rust 🦀 string!");
});

test("should be able to crate latin1 string", (t) => {
  t.is(bindings.createLatin1(), "©¿");
});
