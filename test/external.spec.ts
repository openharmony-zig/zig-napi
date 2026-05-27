import { assertArrayEqual, assertEqual, assertThrows } from "./assert";

type NativeAddon = ESObject;

export function testExternal(native: NativeAddon) {
  const external = native.create_external(10);
  assertEqual(native.get_external(external), 10, "external value");

  native.mutate_external(external, 42);
  assertEqual(native.get_external(external), 42, "mutated external value");

  const sizedExternal = native.create_external_with_size_hint(7);
  assertEqual(native.get_external(sizedExternal), 7, "external with size hint value");
  assertEqual(native.get_external_size_hint(sizedExternal), 128, "external size hint");

  const pair = native.create_external_pair(11);
  assertEqual(pair.length, 2, "external pair length");
  assertEqual(native.get_external(pair[0]), 11, "external pair first value");
  assertEqual(native.get_external(pair[1]), 11, "external pair second value");
  native.mutate_external(pair[0], 12);
  assertEqual(native.get_external(pair[1]), 12, "external pair shared payload");

  const point = native.create_external_point(3, 4);
  assertArrayEqual(
    [native.get_external_point(point).x, native.get_external_point(point).y],
    [3, 4],
    "external point value",
  );

  native.mutate_external_point(point, 5, 6);
  const mutatedPoint = native.get_external_point(point);
  assertArrayEqual([mutatedPoint.x, mutatedPoint.y], [5, 6], "mutated external point");
  assertEqual(native.external_either_kind(external), 1, "external union number kind");
  assertEqual(native.external_either_value(external), 42, "external union number value");
  assertEqual(native.external_either_kind(point), 2, "external union point kind");
  assertEqual(native.external_either_value(point), 11, "external union point value");

  native.reset_detached_external_deinit_count();
  assertEqual(native.deinit_detached_external(), 1, "detached external deinit return");
  assertEqual(native.detached_external_deinit_count(), 1, "detached external deinit count");

  assertThrows(
    () => native.get_external_point(external),
    "External value type does not match expected type",
    "external type mismatch",
  );
  assertThrows(() => native.get_external({}), "Expected external value", "non-external value");
  assertThrows(
    () => native.get_external(native.create_misaligned_external()),
    "External value was not created by zig-napi",
    "misaligned external value",
  );
}
