const napi = @import("napi");

const number = @import("number.zig");
const string = @import("string.zig");
const err = @import("err.zig");
const worker = @import("worker.zig");
const array = @import("array.zig");
const object = @import("object.zig");
const function = @import("function.zig");
const thread_safe_function = @import("thread_safe_function.zig");
const class = @import("class.zig");
const log = @import("log/log.zig");
const buffer = @import("buffer.zig");
const arraybuffer = @import("arraybuffer.zig");
const typedarray = @import("typedarray.zig");
const dataview = @import("dataview.zig");
const reference = @import("reference.zig");
const union_value = @import("union.zig");
const enum_value = @import("enum.zig");

pub const test_i32 = number.test_i32;
pub const test_f32 = number.test_f32;
pub const test_u32 = number.test_u32;

pub const hello = string.hello;
pub const text = string.text;

pub const throw_error = err.throw_error;

pub const fib = worker.fib;
pub const fib_async = worker.fib_async;

pub const get_and_return_array = array.get_and_return_array;
pub const get_named_array = array.get_named_array;
pub const get_arraylist = array.get_arraylist;

pub const get_object = object.get_object;
pub const get_object_optional = object.get_object_optional;
pub const get_optional_object_and_return_optional = object.get_optional_object_and_return_optional;
pub const get_nullable_object = object.get_nullable_object;
pub const return_nullable = object.return_nullable;

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
pub const get_buffer = buffer.get_buffer;
pub const get_buffer_as_string = buffer.get_buffer_as_string;

pub const create_arraybuffer = arraybuffer.create_arraybuffer;
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

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
