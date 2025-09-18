const napi = @import("napi");

const number = @import("number.zig");
const string = @import("string.zig");
const err = @import("err.zig");
const worker = @import("worker.zig");
const array = @import("array.zig");
const object = @import("object.zig");
const function = @import("function.zig");

pub usingnamespace number;
pub usingnamespace string;
pub usingnamespace err;
pub usingnamespace worker;
pub usingnamespace array;
pub usingnamespace object;
pub usingnamespace function;

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
