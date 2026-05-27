const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("error.zig");
const GlobalAllocator = @import("../util/allocator.zig");

const native_wrap_magic: u64 = 0x5a_4e_41_50_49_57_52_50;

const TaggedHeader = struct {
    magic: u64,
    type_name_ptr: [*]const u8,
    type_name_len: usize,
    allocator: std.mem.Allocator,
    value_ptr: ?*anyopaque,
    size_hint: usize,
    memory_adjusted: bool,
    destroy: *const fn (*TaggedHeader) void,

    fn typeName(self: *const TaggedHeader) []const u8 {
        return self.type_name_ptr[0..self.type_name_len];
    }
};

pub fn wrap(env: napi.napi_env, raw_object: napi.napi_value, payload: anytype, size_hint: usize) !void {
    const Payload = @TypeOf(payload);
    const header = try createHeader(Payload, payload, size_hint);
    var owned = true;
    errdefer if (owned) destroyHeaderRaw(header);

    const size_hint_i64 = std.math.cast(i64, size_hint) orelse {
        return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
    };

    const status = napi.napi_wrap(env, raw_object, header, finalizer, null, null);
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
    }
    owned = false;

    if (size_hint == 0) {
        return;
    }

    var adjusted_size: i64 = 0;
    const adjust_status = napi.napi_adjust_external_memory(env, size_hint_i64, &adjusted_size);
    if (adjust_status == napi.napi_ok) {
        header.memory_adjusted = true;
        return;
    }

    var removed: ?*anyopaque = null;
    const remove_status = napi.napi_remove_wrap(env, raw_object, &removed);
    if (remove_status == napi.napi_ok and removed != null) {
        const removed_header: *TaggedHeader = @ptrCast(@alignCast(removed.?));
        destroyHeaderRaw(removed_header);
    }
    return NapiError.Error.fromStatus(NapiError.Status.New(adjust_status));
}

pub fn unwrap(env: napi.napi_env, raw_object: napi.napi_value, comptime T: type) !*T {
    const header = try headerFromObject(env, raw_object, T);
    return @ptrCast(@alignCast(header.value_ptr.?));
}

pub fn unwrapConst(env: napi.napi_env, raw_object: napi.napi_value, comptime T: type) !*const T {
    return try unwrap(env, raw_object, T);
}

pub fn dropWrapped(env: napi.napi_env, raw_object: napi.napi_value, comptime T: type) !void {
    const header = try headerFromObject(env, raw_object, T);

    var removed: ?*anyopaque = null;
    const status = napi.napi_remove_wrap(env, raw_object, &removed);
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
    }
    if (removed == null) {
        return NapiError.Error.fromReason("Object is not wrapped by zig-napi");
    }
    if (removed.? != @as(*anyopaque, @ptrCast(header))) {
        return NapiError.Error.fromReason("Removed native wrap did not match the unwrapped value");
    }

    if (header.memory_adjusted and header.size_hint > 0) {
        var adjusted_size: i64 = 0;
        _ = napi.napi_adjust_external_memory(env, -@as(i64, @intCast(header.size_hint)), &adjusted_size);
        header.memory_adjusted = false;
    }
    destroyHeaderRaw(header);
}

pub fn matches(env: napi.napi_env, raw_object: napi.napi_value, comptime T: type) bool {
    return headerFromObjectInternal(env, raw_object, T, false) != null;
}

fn createHeader(comptime T: type, payload: T, size_hint: usize) !*TaggedHeader {
    const allocator = GlobalAllocator.globalAllocator();
    const stored = try allocator.create(T);
    stored.* = payload;
    errdefer {
        destroyStoredValue(T, allocator, stored);
    }

    const header = try allocator.create(TaggedHeader);
    const type_name = @typeName(T);
    header.* = .{
        .magic = native_wrap_magic,
        .type_name_ptr = type_name.ptr,
        .type_name_len = type_name.len,
        .allocator = allocator,
        .value_ptr = stored,
        .size_hint = size_hint,
        .memory_adjusted = false,
        .destroy = destroyTypedHeader(T),
    };
    return header;
}

fn headerFromObject(env: napi.napi_env, raw_object: napi.napi_value, comptime T: type) !*TaggedHeader {
    return headerFromObjectInternal(env, raw_object, T, true) orelse error.GenericFailure;
}

fn headerFromObjectInternal(
    env: napi.napi_env,
    raw_object: napi.napi_value,
    comptime T: type,
    comptime report_error: bool,
) ?*TaggedHeader {
    var data: ?*anyopaque = null;
    const status = napi.napi_unwrap(env, raw_object, &data);
    if (status != napi.napi_ok) {
        if (report_error) {
            NapiError.last_error = if (status == napi.napi_invalid_arg)
                NapiError.Error.withReason("Object is not wrapped by zig-napi")
            else
                NapiError.Error.withStatus(NapiError.Status.New(status));
        }
        return null;
    }
    if (data == null) {
        if (report_error) {
            NapiError.last_error = NapiError.Error.withReason("Object is not wrapped by zig-napi");
        }
        return null;
    }

    const data_ptr = data.?;
    if (@intFromPtr(data_ptr) % @alignOf(TaggedHeader) != 0) {
        if (report_error) {
            NapiError.last_error = NapiError.Error.withReason("Wrapped object was not created by zig-napi");
        }
        return null;
    }

    const header: *TaggedHeader = @ptrCast(@alignCast(data_ptr));
    if (header.magic != native_wrap_magic) {
        if (report_error) {
            NapiError.last_error = NapiError.Error.withReason("Wrapped object was not created by zig-napi");
        }
        return null;
    }
    if (!std.mem.eql(u8, header.typeName(), @typeName(T))) {
        if (report_error) {
            NapiError.last_error = NapiError.Error.withReason("Native wrapped object type does not match expected type");
        }
        return null;
    }

    return header;
}

fn destroyHeaderRaw(header: *TaggedHeader) void {
    header.destroy(header);
}

fn destroyStoredValue(comptime T: type, allocator: std.mem.Allocator, stored: *T) void {
    const previous_allocator = GlobalAllocator.globalAllocator();
    GlobalAllocator.global_manager.set(allocator);
    defer GlobalAllocator.global_manager.set(previous_allocator);

    Napi.deinit_napi_value(T, stored.*);
    allocator.destroy(stored);
}

fn destroyTypedHeader(comptime T: type) *const fn (*TaggedHeader) void {
    return struct {
        fn destroy(header: *TaggedHeader) void {
            const allocator = header.allocator;
            if (header.value_ptr) |ptr| {
                const stored: *T = @ptrCast(@alignCast(ptr));
                destroyStoredValue(T, allocator, stored);
                header.value_ptr = null;
            }
            header.magic = 0;
            allocator.destroy(header);
        }
    }.destroy;
}

fn finalizer(
    env: napi.napi_env,
    data: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (data) |raw| {
        const header: *TaggedHeader = @ptrCast(@alignCast(raw));
        if (header.magic != native_wrap_magic) return;
        if (header.memory_adjusted and header.size_hint > 0) {
            var adjusted_size: i64 = 0;
            _ = napi.napi_adjust_external_memory(env, -@as(i64, @intCast(header.size_hint)), &adjusted_size);
            header.memory_adjusted = false;
        }
        destroyHeaderRaw(header);
    }
}
