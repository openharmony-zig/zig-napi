import { assertArrayEqual, assertEqual, assertNullish } from "./assert";

type NativeAddon = ESObject;

function assertPayload(value: ESObject, title: string, count: number, message: string) {
  assertEqual(value.title, title, `${message}.title`);
  assertEqual(value.count, count, `${message}.count`);
}

export function testUnionsAndEnums(native: NativeAddon) {
  assertEqual(native.union_identity(42), 42, "union_identity number");
  assertEqual(native.union_identity("forty-two"), "forty-two", "union_identity text");
  assertEqual(native.make_union(true), 42, "make_union number");
  assertEqual(native.make_union(false), "hello", "make_union text");
  assertEqual(native.union_kind(42), "number", "union_kind number");
  assertEqual(native.union_kind("forty-two"), "text", "union_kind text");

  assertPayload(
    native.object_or_text_identity({ title: "payload", count: 5 }),
    "payload",
    5,
    "object_or_text payload",
  );
  assertEqual(native.object_or_text_identity("plain"), "plain", "object_or_text text");
  assertPayload(native.make_object_or_text(true), "hello", 2, "make_object_or_text payload");
  assertEqual(native.make_object_or_text(false), "plain", "make_object_or_text text");

  assertPayload(
    native.object_or_array_identity({ title: "list-payload", count: 6 }),
    "list-payload",
    6,
    "object_or_array payload",
  );
  assertArrayEqual(native.object_or_array_identity([1, 2, 3]), [1, 2, 3], "object_or_array list");
  assertArrayEqual(
    native.tuple_or_text_identity([1, true, "tuple"]),
    [1, true, "tuple"],
    "tuple_or_text tuple",
  );
  assertEqual(native.tuple_or_text_identity("tuple-text"), "tuple-text", "tuple_or_text text");

  assertEqual(native.flip_flag_or_increment(true), false, "flip_flag_or_increment bool");
  assertEqual(native.flip_flag_or_increment(9), 10, "flip_flag_or_increment number");

  assertEqual(native.enum_identity(1), 1, "enum_identity");
  assertEqual(native.favorite_color(), 2, "favorite_color");
  assertEqual(native.is_primary(4), true, "is_primary");
  assertEqual(native.string_enum_identity("Red"), "Red", "string_enum_identity");
  assertEqual(native.favorite_string_color(), "Blue", "favorite_string_color");

  assertEqual(native.color_or_text_identity(1), 1, "color_or_text color");
  assertEqual(native.color_or_text_identity("fallback"), "fallback", "color_or_text text");
  assertEqual(native.favorite_color_or_text(true), 4, "favorite_color_or_text color");
  assertEqual(native.favorite_color_or_text(false), "fallback", "favorite_color_or_text text");

  assertEqual(native.maybe_text_or_count_identity("maybe"), "maybe", "maybe_text string");
  assertNullish(native.maybe_text_or_count_identity(null), "maybe_text null");
  assertEqual(native.maybe_text_or_count_identity(8), 8, "maybe_text count");
  assertNullish(native.make_maybe_text_or_count(true), "make_maybe_text null");
  assertEqual(native.make_maybe_text_or_count(false), 7, "make_maybe_text count");

  const madeBuffer = native.make_buffer_or_text(true);
  assertEqual(native.get_buffer(madeBuffer), 16, "make_buffer_or_text buffer");
  assertEqual(
    native.get_buffer(native.buffer_or_text_identity(madeBuffer)),
    16,
    "buffer_or_text buffer",
  );
  assertEqual(native.buffer_or_text_identity("buffer-text"), "buffer-text", "buffer_or_text text");
  assertEqual(native.make_buffer_or_text(false), "buffer-fallback", "make_buffer_or_text text");

  const madeArrayBuffer = native.make_arraybuffer_or_array(true);
  assertEqual(native.get_arraybuffer(madeArrayBuffer), 16, "make_arraybuffer_or_array arraybuffer");
  assertEqual(
    native.get_arraybuffer(native.arraybuffer_or_array_identity(madeArrayBuffer)),
    16,
    "arraybuffer_or_array arraybuffer",
  );
  assertArrayEqual(
    native.arraybuffer_or_array_identity([4, 5]),
    [4, 5],
    "arraybuffer_or_array list",
  );
  assertArrayEqual(
    native.make_arraybuffer_or_array(false),
    [1, 2, 3],
    "make_arraybuffer_or_array list",
  );

  assertPayload(
    native.payload_or_color_identity({ title: "mixed", count: 11 }),
    "mixed",
    11,
    "payload_or_color payload",
  );
  assertEqual(native.payload_or_color_identity(1), 1, "payload_or_color color");
  assertPayload(native.make_payload_or_color(true), "mixed", 9, "make_payload_or_color payload");
  assertEqual(native.make_payload_or_color(false), 1, "make_payload_or_color color");

  assertPayload(
    native.payload_or_string_color_identity({ title: "string-color", count: 12 }),
    "string-color",
    12,
    "payload_or_string_color payload",
  );
  assertEqual(
    native.payload_or_string_color_identity("Red"),
    "Red",
    "payload_or_string_color color",
  );
  assertPayload(
    native.make_payload_or_string_color(true),
    "string-enum",
    3,
    "make_payload_or_string_color payload",
  );
  assertEqual(
    native.make_payload_or_string_color(false),
    "Green",
    "make_payload_or_string_color color",
  );
}
