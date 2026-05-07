import { assert, assertEqual } from "./assert";
import { runSuite } from "./native";

runSuite("__ZIG_NAPI_ALLOCATOR_BUILTIN_RESULT__", (native) => {
  assertEqual(native.allocator_kind(), "builtin-page", "builtin allocator kind");
  assert(native.manual_allocation_roundtrip(64), "builtin allocator manual roundtrip");

  const copied = native.make_copied_buffer();
  assertEqual(native.input_sum(copied), 20, "builtin copied buffer sum");

  const owned = native.make_js_owned_buffer(5);
  assertEqual(native.input_sum(owned), 25, "builtin js-owned buffer sum");

  assertEqual(native.input_sum(native.make_copied_buffer()), 20, "builtin input sum");
});
