import { assert, assertArrayEqual, assertEqual } from "./assert";

type NativeAddon = ESObject;

export function exerciseSyncWrappers(native: NativeAddon) {
  for (let i = 0; i < 250; i++) {
    const suffix = `${i}-${i % 17}`;
    assert(native.tracked_alloc_roundtrip((i % 128) + 1), "tracked allocator roundtrip");
    assertEqual(native.hello(`ArkTS-${suffix}`), `Hello, ArkTS-${suffix}!`, "string wrapper");

    const objectValue = native.get_object({
      name: `name-${suffix}`,
      age: i,
      is_student: i % 2 === 0,
    });
    assertEqual(objectValue.name, `name-${suffix}`, "object.name");
    assertEqual(objectValue.age, i, "object.age");
    assertEqual(objectValue.is_student, i % 2 === 0, "object.is_student");

    const optionalValue = native.get_optional_object({ name: `optional-${suffix}` });
    assertEqual(optionalValue.name, `optional-${suffix}`, "optional.name");
    assertEqual(optionalValue.age, 18, "optional.age");
    assertEqual(optionalValue.is_student, true, "optional.is_student");
    assertEqual(native.nullable_name_is_null(null), true, "nullable null");
    assertEqual(native.nullable_name_is_null(`nullable-${suffix}`), false, "nullable string");

    assertArrayEqual(native.get_named_array([i, i % 2 === 0, `tuple-${suffix}`]), [i, i % 2 === 0, `tuple-${suffix}`], "tuple roundtrip");
    assertEqual(native.array_sum([1, 2, 3, i]), i + 6, "array sum");
    assertEqual(native.arraylist_sum([1, 2, 3, i]), i + 6, "arraylist sum");
    assertEqual(native.nested_summary({
      title: `nested-${suffix}`,
      values: [1, 2, 3],
      tuple: [i, true, `tuple-${suffix}`],
      maybe: i % 2 === 0 ? `maybe-${suffix}` : null,
    }) > 0, true, "nested summary");

    assertEqual(native.union_kind(`variant-${suffix}`), "text", "union text");
    assertEqual(native.union_kind(i), "number", "union number");

    const createdFunction = native.create_function();
    assertEqual(createdFunction(19, 23), 42, "create function call");
    assertEqual(native.call_function((left: number, right: number) => left + right), 42, "function callback");
    assertEqual(native.call_function_with_reference((left: number, right: number) => left + right), 42, "function reference");
    assertEqual(native.function_reference_ref_count((left: number, right: number) => left + right), 2, "reference ref count");

    assertEqual(String(native.create_bigint_value()), "9007199254740993", "bigint return");
    assertEqual(native.bigint_to_i64(native.create_small_bigint_value()), 42, "bigint input");
  }
}
