import { assertArrayEqual, assertEqual, assertNullish } from "./assert";

type NativeAddon = ESObject;

export function testObjectsAndArrays(native: NativeAddon) {
  assertArrayEqual(native.get_and_return_array([1, 2, 3]), [1, 2, 3], "array roundtrip");
  assertArrayEqual(native.get_arraylist([3, 2, 1]), [3, 2, 1], "arraylist roundtrip");
  assertArrayEqual(
    native.get_named_array([7, true, "tuple"]),
    [7, true, "tuple"],
    "tuple roundtrip",
  );

  const objectResult = native.get_object({
    name: "Ada",
    age: 36,
    is_student: false,
  });
  assertEqual(objectResult.name, "Ada", "object.name");
  assertEqual(objectResult.age, 36, "object.age");
  assertEqual(objectResult.is_student, false, "object.is_student");

  const optionalDefaults = native.get_object_optional({ name: "Defaulted" });
  assertEqual(optionalDefaults.name, "Defaulted", "object optional.name");
  assertEqual(optionalDefaults.age, 18, "object optional default age");
  assertEqual(optionalDefaults.is_student, true, "object optional default is_student");

  const optionalRoundtrip = native.get_optional_object_and_return_optional({
    name: "Present",
    age: 20,
    is_student: false,
  });
  assertEqual(optionalRoundtrip.name, "Present", "optional roundtrip.name");
  assertEqual(optionalRoundtrip.age, 20, "optional roundtrip.age");
  assertEqual(optionalRoundtrip.is_student, false, "optional roundtrip.is_student");

  assertEqual(
    native.get_nullable_object({ name: "Nullable" }).name,
    "Nullable",
    "nullable object value",
  );
  assertNullish(native.get_nullable_object({ name: null }).name, "nullable object null");
  assertNullish(native.return_nullable().name, "return_nullable");
}
