const napi = @import("napi");

const tracker = @import("tracker.zig");
const sync = @import("sync.zig");
const binary = @import("binary.zig");
const classes = @import("classes.zig");
const async_tests = @import("async.zig");
const finalizer_state = @import("finalizer_state.zig");

pub const leak_tracker_start = tracker.leak_tracker_start;
pub const leak_tracker_finish = tracker.leak_tracker_finish;
pub const leak_tracker_abort = tracker.leak_tracker_abort;
pub const tracked_alloc_roundtrip = tracker.tracked_alloc_roundtrip;
pub const begin_finalizer_state_check = finalizer_state.begin_finalizer_state_check;

pub const hello = sync.hello;
pub const get_object = sync.get_object;
pub const get_optional_object = sync.get_optional_object;
pub const nullable_name_is_null = sync.nullable_name_is_null;
pub const get_named_array = sync.get_named_array;
pub const array_sum = sync.array_sum;
pub const arraylist_sum = sync.arraylist_sum;
pub const nested_summary = sync.nested_summary;
pub const union_kind = sync.union_kind;
pub const create_function = sync.create_function;
pub const call_function = sync.call_function;
pub const call_function_with_reference = sync.call_function_with_reference;
pub const function_reference_ref_count = sync.function_reference_ref_count;
pub const create_bigint_value = sync.create_bigint_value;
pub const create_small_bigint_value = sync.create_small_bigint_value;
pub const bigint_to_i64 = sync.bigint_to_i64;
pub const manual_resolved_promise = sync.manual_resolved_promise;

pub const create_buffer_copy = binary.create_buffer_copy;
pub const create_buffer_new = binary.create_buffer_new;
pub const create_external_buffer = binary.create_external_buffer;
pub const buffer_length = binary.buffer_length;
pub const buffer_first_byte = binary.buffer_first_byte;
pub const create_arraybuffer_copy = binary.create_arraybuffer_copy;
pub const create_arraybuffer_new = binary.create_arraybuffer_new;
pub const create_external_arraybuffer = binary.create_external_arraybuffer;
pub const arraybuffer_length = binary.arraybuffer_length;
pub const arraybuffer_first_byte = binary.arraybuffer_first_byte;
pub const create_uint8_typedarray_copy = binary.create_uint8_typedarray_copy;
pub const create_int16_typedarray_copy = binary.create_int16_typedarray_copy;
pub const create_uint16_typedarray_copy = binary.create_uint16_typedarray_copy;
pub const create_int32_typedarray_copy = binary.create_int32_typedarray_copy;
pub const create_uint32_typedarray_copy = binary.create_uint32_typedarray_copy;
pub const create_float64_typedarray_copy = binary.create_float64_typedarray_copy;
pub const create_external_uint8_typedarray = binary.create_external_uint8_typedarray;
pub const typedarray_sum = binary.typedarray_sum;
pub const int16_typedarray_sum = binary.int16_typedarray_sum;
pub const uint16_typedarray_sum = binary.uint16_typedarray_sum;
pub const int32_typedarray_sum = binary.int32_typedarray_sum;
pub const uint32_typedarray_sum = binary.uint32_typedarray_sum;
pub const float32_typedarray_sum = binary.float32_typedarray_sum;
pub const float64_typedarray_sum = binary.float64_typedarray_sum;
pub const create_dataview_copy = binary.create_dataview_copy;
pub const create_dataview_new = binary.create_dataview_new;
pub const create_external_dataview = binary.create_external_dataview;
pub const dataview_length = binary.dataview_length;
pub const dataview_uint32_le = binary.dataview_uint32_le;
pub const dataview_accessors_roundtrip = binary.dataview_accessors_roundtrip;
pub const invalid_typedarray_from_arraybuffer = binary.invalid_typedarray_from_arraybuffer;
pub const invalid_dataview_from_arraybuffer = binary.invalid_dataview_from_arraybuffer;
pub const reset_external_finalizer_counts = binary.reset_external_finalizer_counts;
pub const external_finalizer_count = binary.external_finalizer_count;

pub const MemoryClass = classes.MemoryClass;
pub const MemoryClassWithoutInit = classes.MemoryClassWithoutInit;
pub const MemoryFactoryClass = classes.MemoryFactoryClass;
pub const reset_class_finalizer_count = classes.reset_class_finalizer_count;
pub const class_finalizer_count = classes.class_finalizer_count;

pub const memory_async_summary = async_tests.memory_async_summary;
pub const memory_async_summary_single = async_tests.memory_async_summary_single;
pub const memory_async_void = async_tests.memory_async_void;
pub const memory_async_fail = async_tests.memory_async_fail;
pub const memory_async_progress = async_tests.memory_async_progress;
pub const memory_event_mode_progress = async_tests.memory_event_mode_progress;
pub const memory_abortable_count = async_tests.memory_abortable_count;
pub const memory_abortable_slow_count = async_tests.memory_abortable_slow_count;
pub const memory_worker = async_tests.memory_worker;
pub const memory_thread_safe_function = async_tests.memory_thread_safe_function;

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
