import { assertArrayEqual, assertEqual } from "./assert";

type NativeAddon = ESObject;

export function testBinary(native: NativeAddon) {
  const bufferValue = native.create_buffer();
  assertEqual(native.get_buffer(bufferValue), 1024, "buffer length");
  assertEqual(native.get_buffer_as_string(bufferValue).length, 1024, "buffer string length");

  const arrayBufferValue = native.create_arraybuffer();
  assertEqual(native.get_arraybuffer(arrayBufferValue), 1024, "arraybuffer length");
  assertEqual(
    native.get_arraybuffer_as_string(arrayBufferValue).length,
    1024,
    "arraybuffer string length",
  );

  const typedArrayValue = native.create_uint8_typedarray();
  assertEqual(native.get_uint8_typedarray_length(typedArrayValue), 4, "typedarray length");
  assertArrayEqual(Array.from(typedArrayValue), [1, 2, 3, 4], "typedarray content");
  assertEqual(
    native.sum_float32_typedarray(new Float32Array([1.5, 2.5, -1])),
    3,
    "float32 typedarray sum",
  );

  const dataViewValue = native.create_dataview();
  assertEqual(native.get_dataview_length(dataViewValue), 4, "dataview length");
  assertEqual(native.get_dataview_first_byte(dataViewValue), 0x78, "dataview first byte");
  assertEqual(native.get_dataview_uint32_le(dataViewValue), 0x12345678, "dataview uint32 le");
}
