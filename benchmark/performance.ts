declare function requireNapiPreview(name: string, isApp: boolean): ESObject;
declare function print(message: string): void;

const RESULT_PREFIX = "__ZIG_NAPI_BENCHMARK_RESULT__";
const DEFAULT_ITERATIONS = 100000;
const HEAVY_ITERATIONS = 20000;
const WARMUP_ITERATIONS = 2000;

type BenchFn = () => ESObject;
type CallbackInput = (left: number, right: number) => ESObject;

let blackhole: ESObject = undefined;

function fixed3(value: number): string {
  return (Math.round(value * 1000) / 1000).toString();
}

function runOne(fn: BenchFn, iterations: number, nowUs: () => number): number {
  const warmup = Math.min(WARMUP_ITERATIONS, iterations);
  for (let i = 0; i < warmup; i++) {
    blackhole = fn();
  }

  const start = nowUs();
  for (let i = 0; i < iterations; i++) {
    blackhole = fn();
  }
  const end = nowUs();
  return (end - start) / iterations;
}

function printRow(
  moduleName: string,
  apiContent: string,
  iterations: number,
  napiUs: number,
  zigUs: number,
) {
  const diff = zigUs - napiUs;
  const ratio = napiUs === 0 ? 0 : zigUs / napiUs;
  print(
    `| ${moduleName} | ${apiContent} | ${iterations} | ${fixed3(napiUs)} | ${fixed3(
      zigUs,
    )} | ${fixed3(diff)} | ${fixed3(ratio)}x |`,
  );
}

function ensureEqual(actual: ESObject, expected: ESObject, label: string) {
  if (actual !== expected) {
    throw new Error(`${label}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

function validateNative(
  zig: ESObject,
  napi: ESObject,
  objectInput: ESObject,
  arrayInput: number[],
  callbackInput: CallbackInput,
) {
  ensureEqual(zig.zig_add_i32(19, 23), 42, "zig add");
  ensureEqual(napi.napi_add_i32(19, 23), 42, "native N-API add");
  ensureEqual(zig.zig_bool_identity(true), true, "zig bool");
  ensureEqual(napi.napi_bool_identity(true), true, "native N-API bool");
  ensureEqual(
    zig.zig_string_len("OpenHarmony ArkVM"),
    "OpenHarmony ArkVM".length,
    "zig string len",
  );
  ensureEqual(
    napi.napi_string_len("OpenHarmony ArkVM"),
    "OpenHarmony ArkVM".length,
    "native N-API string len",
  );
  ensureEqual(zig.zig_object_read(objectInput), 42, "zig object read");
  ensureEqual(napi.napi_object_read(objectInput), 42, "native N-API object read");
  ensureEqual(zig.zig_array_sum(arrayInput), 36, "zig array sum");
  ensureEqual(napi.napi_array_sum(arrayInput), 36, "native N-API array sum");
  ensureEqual(zig.zig_call_function(callbackInput), 42, "zig callback");
  ensureEqual(napi.napi_call_function(callbackInput), 42, "native N-API callback");

  const zigClass = new zig.ZigBenchClass(1);
  const napiClass = new napi.NapiBenchClass(1);
  ensureEqual(zigClass.value, 1, "zig class getter");
  ensureEqual(napiClass.value, 1, "native N-API class getter");
  zigClass.value = 7;
  napiClass.value = 7;
  ensureEqual(zigClass.add(1), 8, "zig class method");
  ensureEqual(napiClass.add(1), 8, "native N-API class method");

  ensureEqual(zig.zig_arraybuffer_length(zig.zig_new_arraybuffer(16)), 16, "zig arraybuffer");
  ensureEqual(
    napi.napi_arraybuffer_length(napi.napi_new_arraybuffer(16)),
    16,
    "native N-API arraybuffer",
  );
  ensureEqual(zig.zig_buffer_length(zig.zig_new_buffer(16)), 16, "zig buffer");
  ensureEqual(napi.napi_buffer_length(napi.napi_new_buffer(16)), 16, "native N-API buffer");
  ensureEqual(
    zig.zig_uint8array_sum(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])),
    36,
    "zig typedarray sum",
  );
  ensureEqual(
    napi.napi_uint8array_sum(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])),
    36,
    "native N-API typedarray sum",
  );
  ensureEqual(zig.zig_dataview_length(zig.zig_new_dataview(16)), 16, "zig dataview");
  ensureEqual(napi.napi_dataview_length(napi.napi_new_dataview(16)), 16, "native N-API dataview");
}

function main() {
  const zig = requireNapiPreview("zig_benchmark", true) as ESObject;
  const napi = requireNapiPreview("napi_benchmark", true) as ESObject;
  const nowUs = () => napi.bench_now_us() as number;

  const objectInput = { count: 41, flag: true };
  const arrayInput = [1, 2, 3, 4, 5, 6, 7, 8];
  const callbackInput = (left: number, right: number): ESObject => left + right;
  validateNative(zig, napi, objectInput, arrayInput, callbackInput);

  const zigClass = new zig.ZigBenchClass(1);
  const napiClass = new napi.NapiBenchClass(1);
  const zigArrayBuffer = zig.zig_new_arraybuffer(16);
  const napiArrayBuffer = napi.napi_new_arraybuffer(16);
  const zigBuffer = zig.zig_new_buffer(16);
  const napiBuffer = napi.napi_new_buffer(16);
  const uint8Array = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const zigDataView = zig.zig_new_dataview(16);
  const napiDataView = napi.napi_new_dataview(16);

  const cases: ESObject[] = [
    {
      moduleName: "global function",
      apiContent: "void(*)()",
      zig: () => zig.zig_noop(),
      napi: () => napi.napi_noop(),
    },
    {
      moduleName: "primitive",
      apiContent: "i32(i32, i32)",
      zig: () => zig.zig_add_i32(19, 23),
      napi: () => napi.napi_add_i32(19, 23),
    },
    {
      moduleName: "primitive",
      apiContent: "bool(bool)",
      zig: () => zig.zig_bool_identity(true),
      napi: () => napi.napi_bool_identity(true),
    },
    {
      moduleName: "string",
      apiContent: "len(string)",
      zig: () => zig.zig_string_len("OpenHarmony ArkVM"),
      napi: () => napi.napi_string_len("OpenHarmony ArkVM"),
    },
    {
      moduleName: "object",
      apiContent: "read properties",
      zig: () => zig.zig_object_read(objectInput),
      napi: () => napi.napi_object_read(objectInput),
    },
    {
      moduleName: "array",
      apiContent: "sum(number[])",
      zig: () => zig.zig_array_sum(arrayInput),
      napi: () => napi.napi_array_sum(arrayInput),
    },
    {
      moduleName: "function",
      apiContent: "call callback",
      zig: () => zig.zig_call_function(callbackInput),
      napi: () => napi.napi_call_function(callbackInput),
    },
    {
      moduleName: "class",
      apiContent: "constructor",
      iterations: HEAVY_ITERATIONS,
      zig: () => new zig.ZigBenchClass(1),
      napi: () => new napi.NapiBenchClass(1),
    },
    {
      moduleName: "class",
      apiContent: "getter",
      zig: () => zigClass.value,
      napi: () => napiClass.value,
    },
    {
      moduleName: "class",
      apiContent: "setter",
      zig: () => {
        zigClass.value = 7;
        return zigClass.value;
      },
      napi: () => {
        napiClass.value = 7;
        return napiClass.value;
      },
    },
    {
      moduleName: "class",
      apiContent: "method",
      zig: () => zigClass.add(1),
      napi: () => napiClass.add(1),
    },
    {
      moduleName: "ArrayBuffer",
      apiContent: "constructor",
      iterations: HEAVY_ITERATIONS,
      zig: () => zig.zig_new_arraybuffer(16),
      napi: () => napi.napi_new_arraybuffer(16),
    },
    {
      moduleName: "ArrayBuffer",
      apiContent: "byteLength",
      zig: () => zig.zig_arraybuffer_length(zigArrayBuffer),
      napi: () => napi.napi_arraybuffer_length(napiArrayBuffer),
    },
    {
      moduleName: "Buffer",
      apiContent: "constructor",
      iterations: HEAVY_ITERATIONS,
      zig: () => zig.zig_new_buffer(16),
      napi: () => napi.napi_new_buffer(16),
    },
    {
      moduleName: "Buffer",
      apiContent: "length",
      zig: () => zig.zig_buffer_length(zigBuffer),
      napi: () => napi.napi_buffer_length(napiBuffer),
    },
    {
      moduleName: "TypedArray",
      apiContent: "Uint8Array constructor",
      iterations: HEAVY_ITERATIONS,
      zig: () => zig.zig_new_uint8array(16),
      napi: () => napi.napi_new_uint8array(16),
    },
    {
      moduleName: "TypedArray",
      apiContent: "Uint8Array sum",
      zig: () => zig.zig_uint8array_sum(uint8Array),
      napi: () => napi.napi_uint8array_sum(uint8Array),
    },
    {
      moduleName: "DataView",
      apiContent: "constructor",
      iterations: HEAVY_ITERATIONS,
      zig: () => zig.zig_new_dataview(16),
      napi: () => napi.napi_new_dataview(16),
    },
    {
      moduleName: "DataView",
      apiContent: "byteLength",
      zig: () => zig.zig_dataview_length(zigDataView),
      napi: () => napi.napi_dataview_length(napiDataView),
    },
  ];

  print("__ZIG_NAPI_BENCHMARK_TABLE__");
  print(
    "| module | api content | iterations | native C N-API avg (us) | zig-napi avg (us) | diff (us) | ratio |",
  );
  print("| --- | --- | ---: | ---: | ---: | ---: | ---: |");

  for (let i = 0; i < cases.length; i++) {
    const item = cases[i];
    const iterations = item.iterations ? (item.iterations as number) : DEFAULT_ITERATIONS;
    const napiUs = runOne(item.napi as BenchFn, iterations, nowUs);
    const zigUs = runOne(item.zig as BenchFn, iterations, nowUs);
    printRow(item.moduleName as string, item.apiContent as string, iterations, napiUs, zigUs);
  }

  if (blackhole === null) {
    print("__ZIG_NAPI_BENCHMARK_BLACKHOLE__ null");
  }
  print(`${RESULT_PREFIX} status=ok`);
}

try {
  main();
} catch (err) {
  const message = String(err && (err.message || err));
  print(`${RESULT_PREFIX} status=fail message=${message}`);
  throw err;
}
