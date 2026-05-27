const std = @import("std");
const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub const ExternalPoint = struct {
    x: i32,
    y: i32,
};

pub fn create_external(value: u32) !napi.External(u32) {
    return try napi.External(u32).New(value);
}

pub fn create_external_with_size_hint(value: u32) !napi.External(u32) {
    return try napi.External(u32).NewWithSizeHint(value, 128);
}

pub fn create_external_pair(value: u32) ![2]napi.External(u32) {
    const external = try napi.External(u32).New(value);
    return .{ external, external };
}

const ForeignExternalHint = struct {
    allocator: std.mem.Allocator,
    ptr: [*]u64,
    len: usize,

    fn destroy(self: *ForeignExternalHint) void {
        const allocator_value = self.allocator;
        allocator_value.free(self.ptr[0..self.len]);
        allocator_value.destroy(self);
    }
};

fn foreignExternalFinalizer(
    _: c.napi_env,
    _: ?*anyopaque,
    hint: ?*anyopaque,
) callconv(.c) void {
    if (hint) |raw_hint| {
        const external_hint: *ForeignExternalHint = @ptrCast(@alignCast(raw_hint));
        external_hint.destroy();
    }
}

pub fn create_misaligned_external(env: napi.Env) !c.napi_value {
    const allocator_value = napi.globalAllocator();
    const storage = try allocator_value.alloc(u64, 2);
    errdefer allocator_value.free(storage);

    const hint = try allocator_value.create(ForeignExternalHint);
    errdefer allocator_value.destroy(hint);
    hint.* = .{
        .allocator = allocator_value,
        .ptr = storage.ptr,
        .len = storage.len,
    };

    const byte_ptr: [*]u8 = @ptrCast(storage.ptr);
    var raw: c.napi_value = undefined;
    const status = c.napi_create_external(
        env.raw,
        @ptrCast(byte_ptr + 1),
        foreignExternalFinalizer,
        hint,
        &raw,
    );
    if (status != c.napi_ok) {
        return napi.Error.fromStatus(napi.Status.New(status));
    }
    return raw;
}

pub fn get_external(external: napi.External(u32)) u32 {
    return external.value().*;
}

pub fn get_external_size_hint(external: napi.External(u32)) usize {
    return external.sizeHint();
}

pub fn mutate_external(external: napi.External(u32), value: u32) void {
    external.valueMut().* = value;
}

pub fn create_external_point(x: i32, y: i32) !napi.External(ExternalPoint) {
    return try napi.External(ExternalPoint).New(.{ .x = x, .y = y });
}

pub fn get_external_point(external: napi.External(ExternalPoint)) ExternalPoint {
    return external.value().*;
}

pub fn mutate_external_point(external: napi.External(ExternalPoint), x: i32, y: i32) void {
    external.valueMut().* = .{ .x = x, .y = y };
}
