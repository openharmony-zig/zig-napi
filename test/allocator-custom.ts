import { assert, assertEqual } from "./assert";
import { runSuite } from "./native";

runSuite("__ZIG_NAPI_ALLOCATOR_CUSTOM_RESULT__", (native) => {
  assertEqual(native.allocator_kind(), "custom-counting", "custom allocator kind");

  const before = native.allocator_stats();
  assert(native.custom_allocation_roundtrip(64), "custom allocator manual roundtrip");
  const after = native.allocator_stats();
  assert(after.alloc_calls > before.alloc_calls, "custom allocator should observe allocations");
  assert(after.free_calls > before.free_calls, "custom allocator should observe frees");

  const copied = native.make_copied_buffer();
  assertEqual(native.input_sum(copied), 60, "custom copied buffer sum");

  const owned = native.make_js_owned_buffer(5);
  assertEqual(native.input_sum(owned), 45, "custom js-owned buffer sum");

  assertEqual(native.input_sum(native.make_copied_buffer()), 60, "custom input sum");
});
