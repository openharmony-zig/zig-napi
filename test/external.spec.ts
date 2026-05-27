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

  const point = native.create_external_point(3, 4);
  assertArrayEqual(
    [native.get_external_point(point).x, native.get_external_point(point).y],
    [3, 4],
    "external point value",
  );

  native.mutate_external_point(point, 5, 6);
  const mutatedPoint = native.get_external_point(point);
  assertArrayEqual([mutatedPoint.x, mutatedPoint.y], [5, 6], "mutated external point");

  assertThrows(
    () => native.get_external_point(external),
    "External value type does not match expected type",
    "external type mismatch",
  );
  assertThrows(() => native.get_external({}), "Expected external value", "non-external value");
}
