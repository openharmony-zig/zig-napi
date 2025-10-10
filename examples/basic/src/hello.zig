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

pub const call_thread_safe_function = thread_safe_function.call_thread_safe_function;

pub const TestClass = class.TestClass;

pub const test_hilog = log.test_hilog;

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
