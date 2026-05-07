import { assertEqual } from "./assert";

type NativeAddon = ESObject;

export function exerciseFinalizerWrappers(native: NativeAddon) {
  native.begin_finalizer_state_check(128, 96);

  for (let i = 0; i < 32; i++) {
    let bufferValue: ESObject | null = native.create_external_buffer(32);
    assertEqual(native.buffer_length(bufferValue), 32, "external buffer length");
    bufferValue = null;

    let arrayBufferValue: ESObject | null = native.create_external_arraybuffer(32);
    assertEqual(native.arraybuffer_length(arrayBufferValue), 32, "external arraybuffer length");
    arrayBufferValue = null;

    let typedArrayValue: ESObject | null = native.create_external_uint8_typedarray();
    assertEqual(native.typedarray_sum(typedArrayValue), 26, "external typedarray sum");
    typedArrayValue = null;

    let dataViewValue: ESObject | null = native.create_external_dataview();
    assertEqual(native.dataview_uint32_le(dataViewValue), 0x12345678, "external dataview value");
    dataViewValue = null;

    let classValue: ESObject | null = new native.MemoryClass(`class-${i}`, [1, 2, 3, i]);
    assertEqual(classValue.name, `class-${i}`, "class name");
    assertEqual(classValue.total(), i + 6, "class method");
    classValue = null;

    let withoutInit: ESObject | null = new native.MemoryClassWithoutInit();
    assertEqual(withoutInit.total(), 0, "class without init method");
    withoutInit = null;

    let factoryClass: ESObject | null = native.MemoryFactoryClass.initWithFactory(`factory-${i}`, [
      1,
      2,
      3,
      i,
    ]);
    assertEqual(factoryClass.name, `factory-${i}`, "factory class name");
    assertEqual(factoryClass.total(), i + 6, "factory class method");
    factoryClass = null;
  }
}
