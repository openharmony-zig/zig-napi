const napi = @import("napi");
pub const parityReadable = parity.parityReadable;
pub const parityRead = parity.parityRead;
pub const parityReaderCancel = parity.parityReaderCancel;
pub const parityReaderRelease = parity.parityReaderRelease;
pub const parityWritable = parity.parityWritable;
pub const parityWrite = parity.parityWrite;
pub const parityWriterClose = parity.parityWriterClose;
pub const parityWriterAbort = parity.parityWriterAbort;
pub const parityWriterRelease = parity.parityWriterRelease;
pub const parityNativeReadable = parity.parityNativeReadable;
const parity = @import("parity.zig");
pub const parityFeatureVersion = parity.parityFeatureVersion;
pub const parityExternalLatin1 = parity.parityExternalLatin1;
pub const parityExternalUtf16 = parity.parityExternalUtf16;
pub const parityEnvironment = parity.parityEnvironment;
pub const parityDate = parity.parityDate;
pub const parityMetadataObject = parity.parityMetadataObject;
pub const MetadataSchema = parity.MetadataObject;
pub const parityTagged = parity.parityTagged;
pub const paritySymbolFor = parity.paritySymbolFor;
pub const paritySymbol = parity.paritySymbol;
pub const parityThis = parity.parityThis;
pub const parityAsyncGenerator = parity.parityAsyncGenerator;
pub const parityAwaitPromise = parity.parityAwaitPromise;
pub const parityPromise = parity.parityPromise;
pub const parityPromiseCatch = parity.parityPromiseCatch;
pub const parityPromiseFinally = parity.parityPromiseFinally;
pub const parityAsyncMap = parity.parityAsyncMap;
pub const parityAsyncJson = parity.parityAsyncJson;
pub const parityMap = parity.parityMap;
pub const paritySet = parity.paritySet;
pub const parityJson = parity.parityJson;
pub const parityIterator = parity.parityIterator;
pub const parityIteratorSum = parity.parityIteratorSum;
pub const parityAsyncIteratorNext = parity.parityAsyncIteratorNext;
pub const parityTsfnAsync = parity.parityTsfnAsync;
pub const parityTsfnPromise = parity.parityTsfnPromise;
pub const parityTsfnBuilder = parity.parityTsfnBuilder;
pub const parityTsfnBlocking = parity.parityTsfnBlocking;
pub const parityTsfnAbort = parity.parityTsfnAbort;
pub const parityClassInstance = parity.parityClassInstance;
pub const ParityFactory = napi.ClassWithoutInit(parity.ParityFactory);
pub const parityFactoryInstance = parity.parityFactoryInstance;
pub const ParityCounter = napi.Class(parity.ParityCounter);
pub const paritySharedThread = parity.paritySharedThread;
pub const parityWeakClosure = parity.parityWeakClosure;
pub const parityShared = parity.parityShared;
pub const NamespacedCounter = napi.Class(parity.NamespacedCounter);
pub const parityNamespaced = parity.parityNamespaced;
pub const MetadataCounter = napi.Class(parity.MetadataCounter);
pub const napi_config = .{
    .MetadataSchema = napi.ExportOptions{ .namespace = "parityTools" },
    .NamespacedCounter = napi.ExportOptions{ .name = "RenamedCounter", .namespace = "parityTools" },
    .parityFunctionName = napi.ExportOptions{ .name = "functionName", .namespace = "parityTools" },
};
pub const parityStringLengths = parity.parityStringLengths;
pub const parityLatin1 = parity.parityLatin1;
pub const parityObject = parity.parityObject;
pub const parityApply = parity.parityApply;
pub const parityBind = parity.parityBind;
pub const parityConstruct = parity.parityConstruct;
pub const parityFunctionName = parity.parityFunctionName;
pub const parityClosure = parity.parityClosure;
pub const parityScope = parity.parityScope;
pub const parityScript = parity.parityScript;

const number = @import("number.zig");
const string = @import("string.zig");
const err = @import("err.zig");
const worker = @import("worker.zig");
const async_examples = @import("async.zig");
const array = @import("array.zig");
const object = @import("object.zig");
const function = @import("function.zig");
const thread_safe_function = @import("thread_safe_function.zig");
const class = @import("class.zig");
const builtin = @import("builtin");
const log = if (builtin.target.abi.isOpenHarmony()) @import("log/log.zig") else struct {
    pub fn test_hilog() void {}
};
const buffer = @import("buffer.zig");
const arraybuffer = @import("arraybuffer.zig");
const typedarray = @import("typedarray.zig");
const dataview = @import("dataview.zig");
const reference = @import("reference.zig");
const union_value = @import("union.zig");
const enum_value = @import("enum.zig");
const external = @import("external.zig");

pub const test_i32 = number.test_i32;
pub const test_f32 = number.test_f32;
pub const test_u32 = number.test_u32;
pub const custom_add = napi.dts(number.test_i32, "(left: Number, right: Number) => Number");

pub const hello = string.hello;
pub const raw_string_len = string.raw_string_len;
pub const copied_string_len = string.copied_string_len;
pub const text = string.text;
pub const custom_text = string.custom_text;
pub const custom_string = string.custom_string;

pub const throw_error = err.throw_error;
pub const result_ok = err.result_ok;
pub const result_error = err.result_error;
pub const result_void_ok = err.result_void_ok;
pub const result_after_try = err.result_after_try;
pub const throw_zig_error = err.throw_zig_error;
pub const throw_zig_error_value = err.throw_zig_error_value;

pub const fib = worker.fib;
pub const fib_async = async_examples.fib_async;
pub const fib_async_progress = async_examples.fib_async_progress;
pub const read_file_async = async_examples.read_file_async;
pub const read_file_summary_async = async_examples.read_file_summary_async;
pub const parallel_read_files_async = async_examples.parallel_read_files_async;
pub const async_math_single = async_examples.async_math_single;
pub const async_void_thread = async_examples.async_void_thread;
pub const async_fail_thread = async_examples.async_fail_thread;
pub const count_async_progress_thread = async_examples.count_async_progress_thread;
pub const event_mode_progress_async = async_examples.event_mode_progress_async;
pub const abortable_count_async = async_examples.abortable_count_async;

pub const get_and_return_array = array.get_and_return_array;
pub const get_named_array = array.get_named_array;
pub const get_arraylist = array.get_arraylist;
pub const raw_array_sum = array.raw_array_sum;
pub const raw_array_create = array.raw_array_create;

pub const get_object = object.get_object;
pub const get_object_optional = object.get_object_optional;
pub const get_optional_object_and_return_optional = object.get_optional_object_and_return_optional;
pub const get_nullable_object = object.get_nullable_object;
pub const return_nullable = object.return_nullable;
pub const raw_object_read = object.raw_object_read;
pub const raw_object_create = object.raw_object_create;

pub const call_function = function.call_function;
pub const basic_function = function.basic_function;
pub const create_function = function.create_function;
pub const call_function_with_reference = reference.call_function_with_reference;

pub const call_thread_safe_function = thread_safe_function.call_thread_safe_function;

pub const TestClass = class.TestClass;
pub const TestWithInitClass = class.TestWithInitClass;
pub const TestWithoutInitClass = class.TestWithoutInitClass;
pub const TestFactoryClass = class.TestFactoryClass;

pub const test_hilog = log.test_hilog;

pub const create_buffer = buffer.create_buffer;
pub const create_empty_buffer_new = buffer.create_empty_buffer_new;
pub const create_empty_buffer_copy = buffer.create_empty_buffer_copy;
pub const create_empty_external_buffer = buffer.create_empty_external_buffer;
pub const get_buffer = buffer.get_buffer;
pub const get_buffer_as_string = buffer.get_buffer_as_string;

pub const create_arraybuffer = arraybuffer.create_arraybuffer;
pub const create_empty_arraybuffer_new = arraybuffer.create_empty_arraybuffer_new;
pub const create_empty_arraybuffer_copy = arraybuffer.create_empty_arraybuffer_copy;
pub const create_empty_external_arraybuffer = arraybuffer.create_empty_external_arraybuffer;
pub const get_arraybuffer = arraybuffer.get_arraybuffer;
pub const get_arraybuffer_as_string = arraybuffer.get_arraybuffer_as_string;

pub const create_uint8_typedarray = typedarray.create_uint8_typedarray;
pub const get_uint8_typedarray_length = typedarray.get_uint8_typedarray_length;
pub const sum_float32_typedarray = typedarray.sum_float32_typedarray;

pub const create_dataview = dataview.create_dataview;
pub const get_dataview_length = dataview.get_dataview_length;
pub const get_dataview_first_byte = dataview.get_dataview_first_byte;
pub const get_dataview_uint32_le = dataview.get_dataview_uint32_le;

pub const union_identity = union_value.union_identity;
pub const make_union = union_value.make_union;
pub const union_kind = union_value.union_kind;
pub const object_or_text_identity = union_value.object_or_text_identity;
pub const make_object_or_text = union_value.make_object_or_text;
pub const object_or_array_identity = union_value.object_or_array_identity;
pub const tuple_or_text_identity = union_value.tuple_or_text_identity;
pub const flip_flag_or_increment = union_value.flip_flag_or_increment;
pub const color_or_text_identity = union_value.color_or_text_identity;
pub const favorite_color_or_text = union_value.favorite_color_or_text;
pub const maybe_text_or_count_identity = union_value.maybe_text_or_count_identity;
pub const make_maybe_text_or_count = union_value.make_maybe_text_or_count;
pub const buffer_or_text_identity = union_value.buffer_or_text_identity;
pub const make_buffer_or_text = union_value.make_buffer_or_text;
pub const arraybuffer_or_array_identity = union_value.arraybuffer_or_array_identity;
pub const make_arraybuffer_or_array = union_value.make_arraybuffer_or_array;
pub const payload_or_color_identity = union_value.payload_or_color_identity;
pub const make_payload_or_color = union_value.make_payload_or_color;
pub const payload_or_string_color_identity = union_value.payload_or_string_color_identity;
pub const make_payload_or_string_color = union_value.make_payload_or_string_color;

pub const Color = enum_value.Color;
pub const StringColor = enum_value.StringColor;
pub const enum_identity = enum_value.enum_identity;
pub const favorite_color = enum_value.favorite_color;
pub const is_primary = enum_value.is_primary;
pub const string_enum_identity = enum_value.string_enum_identity;
pub const favorite_string_color = enum_value.favorite_string_color;

pub const create_external = external.create_external;
pub const create_external_with_size_hint = external.create_external_with_size_hint;
pub const create_external_pair = external.create_external_pair;
pub const create_misaligned_external = external.create_misaligned_external;
pub const get_external = external.get_external;
pub const get_external_size_hint = external.get_external_size_hint;
pub const mutate_external = external.mutate_external;
pub const create_external_point = external.create_external_point;
pub const get_external_point = external.get_external_point;
pub const mutate_external_point = external.mutate_external_point;
pub const external_either_kind = external.external_either_kind;
pub const external_either_value = external.external_either_value;
pub const reset_detached_external_deinit_count = external.reset_detached_external_deinit_count;
pub const detached_external_deinit_count = external.detached_external_deinit_count;
pub const deinit_detached_external = external.deinit_detached_external;

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
