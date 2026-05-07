const std = @import("std");
const napi = @import("napi");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const Stats = @import("counting_allocator.zig").Stats;

var custom_allocator_state = CountingAllocator.init(std.heap.page_allocator);
pub const napi_allocator = custom_allocator_state.allocator();

pub fn allocator_kind() []const u8 {
    return "custom-counting";
}

pub fn allocator_stats() Stats {
    return custom_allocator_state.stats();
}

pub fn custom_allocation_roundtrip(len: u32) bool {
    const allocator = napi.globalAllocator();
    const bytes = allocator.alloc(u8, len) catch return false;
    defer allocator.free(bytes);

    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    return bytes.len == len and (len == 0 or bytes[0] == 0);
}

pub fn make_js_owned_buffer(env: napi.Env, len: u32) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index + 7) % 251);
    }
    return try napi.Buffer.from(env, bytes);
}

pub fn make_copied_buffer(env: napi.Env) !napi.Buffer {
    const bytes = [_]u8{ 11, 13, 17, 19 };
    return try napi.Buffer.copy(env, &bytes);
}

pub fn input_sum(input: napi.Buffer) u32 {
    var sum: u32 = 0;
    for (input.asConstSlice()) |byte| {
        sum += byte;
    }
    return sum;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
