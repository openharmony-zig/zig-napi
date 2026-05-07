import { assertEqual, assertThrows } from "./assert";

type NativeAddon = ESObject;

export function exerciseBinaryWrappers(native: NativeAddon) {
  for (let i = 0; i < 250; i++) {
    const bufferValue = native.create_buffer_copy(64);
    assertEqual(native.buffer_length(bufferValue), 64, "buffer copy length");
    assertEqual(native.buffer_first_byte(bufferValue), 0, "buffer first byte");

    const newBufferValue = native.create_buffer_new(32);
    assertEqual(native.buffer_length(newBufferValue), 32, "buffer new length");
    assertEqual(native.buffer_first_byte(newBufferValue), 0x5a, "buffer new first byte");

    const arrayBufferValue = native.create_arraybuffer_copy(64);
    assertEqual(native.arraybuffer_length(arrayBufferValue), 64, "arraybuffer copy length");
    assertEqual(native.arraybuffer_first_byte(arrayBufferValue), 3, "arraybuffer first byte");

    const newArrayBufferValue = native.create_arraybuffer_new(32);
    assertEqual(native.arraybuffer_length(newArrayBufferValue), 32, "arraybuffer new length");
    assertEqual(
      native.arraybuffer_first_byte(newArrayBufferValue),
      0x6b,
      "arraybuffer new first byte",
    );

    const typedArrayValue = native.create_uint8_typedarray_copy();
    assertEqual(native.typedarray_sum(typedArrayValue), 10, "typedarray created sum");
    assertEqual(native.typedarray_sum(new Uint8Array([1, 2, 3, 4])), 10, "typedarray input sum");
    assertEqual(
      native.int16_typedarray_sum(native.create_int16_typedarray_copy()),
      4,
      "int16 typedarray created sum",
    );
    assertEqual(
      native.int16_typedarray_sum(new Int16Array([-1, 2, 3])),
      4,
      "int16 typedarray input sum",
    );
    assertEqual(
      native.uint16_typedarray_sum(native.create_uint16_typedarray_copy()),
      15,
      "uint16 typedarray created sum",
    );
    assertEqual(
      native.uint16_typedarray_sum(new Uint16Array([4, 5, 6])),
      15,
      "uint16 typedarray input sum",
    );
    assertEqual(
      native.int32_typedarray_sum(native.create_int32_typedarray_copy()),
      10,
      "int32 typedarray created sum",
    );
    assertEqual(
      native.int32_typedarray_sum(new Int32Array([-7, 8, 9])),
      10,
      "int32 typedarray input sum",
    );
    assertEqual(
      native.uint32_typedarray_sum(native.create_uint32_typedarray_copy()),
      33,
      "uint32 typedarray created sum",
    );
    assertEqual(
      native.uint32_typedarray_sum(new Uint32Array([10, 11, 12])),
      33,
      "uint32 typedarray input sum",
    );
    assertEqual(
      native.float32_typedarray_sum(new Float32Array([1.5, 2.5, -1])),
      3,
      "float32 typedarray input sum",
    );
    assertEqual(
      native.float64_typedarray_sum(native.create_float64_typedarray_copy()),
      3,
      "float64 typedarray created sum",
    );
    assertEqual(
      native.float64_typedarray_sum(new Float64Array([1.5, 2.25, -0.75])),
      3,
      "float64 typedarray input sum",
    );

    const dataViewValue = native.create_dataview_copy();
    assertEqual(native.dataview_length(dataViewValue), 4, "dataview copy length");
    assertEqual(native.dataview_uint32_le(dataViewValue), 0x12345678, "dataview copy uint32");
    assertEqual(
      native.dataview_uint32_le(new DataView(new Uint8Array([0x78, 0x56, 0x34, 0x12]).buffer)),
      0x12345678,
      "dataview input uint32",
    );

    const newDataViewValue = native.create_dataview_new(8);
    assertEqual(native.dataview_length(newDataViewValue), 8, "dataview new length");
    assertEqual(native.dataview_accessors_roundtrip(), true, "dataview accessor roundtrip");
  }

  assertThrows(() => native.invalid_typedarray_from_arraybuffer(), "invalid typedarray branch");
  assertThrows(() => native.invalid_dataview_from_arraybuffer(), "invalid dataview branch");
}
