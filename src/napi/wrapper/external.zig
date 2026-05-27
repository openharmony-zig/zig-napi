const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("error.zig");
const GlobalAllocator = @import("../util/allocator.zig");

const external_magic: u64 = 0x5a_4e_41_50_49_45_58_54;

const TaggedHeader = struct {
    magic: u64,
    type_name_ptr: [*]const u8,
    type_name_len: usize,
    allocator: std.mem.Allocator,
    value_ptr: ?*anyopaque,
    size_hint: usize,
    ref_count: std.atomic.Value(usize),
    memory_adjusted: bool,
    adjusted_size: i64,
    destroy: *const fn (*TaggedHeader) void,

    fn typeName(self: *const TaggedHeader) []const u8 {
        return self.type_name_ptr[0..self.type_name_len];
    }
};

pub fn External(comptime T: type) type {
    return struct {
        pub const is_napi_external = true;
        pub const external_type = T;

        env: napi.napi_env,
        raw: napi.napi_value,
        header: ?*TaggedHeader,

        const Self = @This();

        pub fn New(payload: T) !Self {
            return try Self.NewWithSizeHint(payload, 0);
        }

        pub fn NewWithSizeHint(payload: T, size_hint: usize) !Self {
            const header = try createHeader(payload, size_hint);
            return Self{
                .env = null,
                .raw = null,
                .header = header,
            };
        }

        pub fn new(payload: T) !Self {
            return try Self.New(payload);
        }

        pub fn newWithSizeHint(payload: T, size_hint: usize) !Self {
            return try Self.NewWithSizeHint(payload, size_hint);
        }

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return Self.from_napi_value(env, raw);
        }

        pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) Self {
            const header = headerFromNapiValue(env, raw, true) orelse return invalid(env, raw);

            return Self{
                .env = env,
                .raw = raw,
                .header = header,
            };
        }

        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) bool {
            return headerFromNapiValue(env, raw, false) != null;
        }

        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            if (self.raw != null) {
                return self.raw;
            }

            const header = self.header orelse {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            };
            const size_hint_i64 = std.math.cast(i64, header.size_hint) orelse {
                _ = destroyDetachedHeader(header);
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            };

            var result: napi.napi_value = undefined;
            retainHeader(header);
            const status = napi.napi_create_external(env, header, externalFinalizer, null, &result);
            if (status != napi.napi_ok) {
                releaseHeader(null, header);
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            if (header.size_hint > 0 and !header.memory_adjusted) {
                var adjusted_size: i64 = 0;
                const adjust_status = napi.napi_adjust_external_memory(
                    env,
                    size_hint_i64,
                    &adjusted_size,
                );
                if (adjust_status == napi.napi_ok) {
                    header.memory_adjusted = true;
                    header.adjusted_size = adjusted_size;
                }
            }

            return result;
        }

        pub fn Deinit(self: *Self) void {
            self.deinit();
        }

        pub fn deinit(self: *Self) void {
            const header = self.header orelse return;
            if (destroyDetachedHeader(header)) {
                self.header = null;
                self.raw = null;
                self.env = null;
            }
        }

        fn headerFromNapiValue(env: napi.napi_env, raw: napi.napi_value, comptime report_error: bool) ?*TaggedHeader {
            var value_type: napi.napi_valuetype = undefined;
            const type_status = napi.napi_typeof(env, raw, &value_type);
            if (type_status != napi.napi_ok) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(type_status));
                }
                return null;
            }
            if (value_type != napi.napi_external) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withCodeAndMessage("InvalidArg", "Expected external value");
                }
                return null;
            }

            var data: ?*anyopaque = null;
            const status = napi.napi_get_value_external(env, raw, &data);
            if (status != napi.napi_ok) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                }
                return null;
            }
            if (data == null) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.InvalidArg);
                }
                return null;
            }

            const data_ptr = data.?;
            if (@intFromPtr(data_ptr) % @alignOf(TaggedHeader) != 0) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withCodeAndMessage("InvalidArg", "External value was not created by zig-napi");
                }
                return null;
            }

            const header: *TaggedHeader = @ptrCast(@alignCast(data_ptr));
            if (header.magic != external_magic) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withCodeAndMessage("InvalidArg", "External value was not created by zig-napi");
                }
                return null;
            }
            if (!std.mem.eql(u8, header.typeName(), @typeName(T))) {
                if (report_error) {
                    NapiError.last_error = NapiError.Error.withCodeAndMessage("InvalidArg", "External value type does not match expected type");
                }
                return null;
            }

            return header;
        }

        pub fn value(self: Self) *const T {
            return self.asConstPtr();
        }

        pub fn valueMut(self: Self) *T {
            return self.asPtr();
        }

        pub fn asConstPtr(self: Self) *const T {
            return @ptrCast(@alignCast(self.header.?.value_ptr.?));
        }

        pub fn asPtr(self: Self) *T {
            return @ptrCast(@alignCast(self.header.?.value_ptr.?));
        }

        pub fn sizeHint(self: Self) usize {
            return self.header.?.size_hint;
        }

        pub fn adjustedSize(self: Self) i64 {
            return self.header.?.adjusted_size;
        }

        fn invalid(env: napi.napi_env, raw: napi.napi_value) Self {
            return Self{
                .env = env,
                .raw = raw,
                .header = null,
            };
        }

        fn createHeader(payload: T, size_hint: usize) !*TaggedHeader {
            const allocator = GlobalAllocator.globalAllocator();
            const stored = try allocator.create(T);
            stored.* = payload;
            errdefer {
                Napi.deinit_napi_value(T, stored.*);
                allocator.destroy(stored);
            }

            const header = try allocator.create(TaggedHeader);
            const type_name = @typeName(T);
            header.* = .{
                .magic = external_magic,
                .type_name_ptr = type_name.ptr,
                .type_name_len = type_name.len,
                .allocator = allocator,
                .value_ptr = stored,
                .size_hint = size_hint,
                .ref_count = std.atomic.Value(usize).init(0),
                .memory_adjusted = false,
                .adjusted_size = 0,
                .destroy = destroyHeader,
            };
            return header;
        }

        fn destroyHeader(header: *TaggedHeader) void {
            const allocator = header.allocator;
            if (header.value_ptr) |ptr| {
                const stored: *T = @ptrCast(@alignCast(ptr));
                Napi.deinit_napi_value(T, stored.*);
                allocator.destroy(stored);
                header.value_ptr = null;
            }
            header.magic = 0;
            allocator.destroy(header);
        }

        fn destroyDetached(self: Self) void {
            if (self.header) |header| {
                _ = destroyDetachedHeader(header);
            }
        }
    };
}

fn destroyDetachedHeader(header: *TaggedHeader) bool {
    if (header.ref_count.load(.acquire) != 0) return false;
    header.destroy(header);
    return true;
}

fn retainHeader(header: *TaggedHeader) void {
    _ = header.ref_count.fetchAdd(1, .monotonic);
}

fn releaseHeader(env: napi.napi_env, header: *TaggedHeader) void {
    const previous = header.ref_count.fetchSub(1, .acq_rel);
    if (previous != 1) return;

    if (env != null and header.memory_adjusted and header.size_hint > 0) {
        var adjusted_size: i64 = 0;
        _ = napi.napi_adjust_external_memory(env, -@as(i64, @intCast(header.size_hint)), &adjusted_size);
    }

    header.destroy(header);
}

fn externalFinalizer(
    env: napi.napi_env,
    data: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (data) |raw| {
        const header: *TaggedHeader = @ptrCast(@alignCast(raw));
        if (header.magic != external_magic) return;

        releaseHeader(env, header);
    }
}
