const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Object = @import("object.zig").Object;
const Napi = @import("../util/napi.zig").Napi;
const Error = @import("../wrapper/error.zig");

/// An explicit discriminant avoids ambiguity between same-shaped variants.
pub fn TaggedUnion(comptime T: type, comptime tag: [:0]const u8, comptime payload: [:0]const u8) type {
    if (@typeInfo(T) != .@"union" or @typeInfo(T).@"union".tag_type == null) @compileError("TaggedUnion requires union(enum)");
    return struct {
        value: T,
        pub const napi_custom = true;
        pub const napi_ts_kind = "tagged-union";
        pub const napi_value_type = T;
        pub const napi_tag_name = tag;
        pub const napi_payload_name = payload;
        const Self = @This();
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            var kind: napi.napi_valuetype = undefined;
            const status = napi.napi_typeof(env, raw, &kind);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return kind == napi.napi_object;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, allocator: std.mem.Allocator) !Self {
            var tag_raw: napi.napi_value = null;
            var status = napi.napi_get_named_property(env, raw, tag.ptr, &tag_raw);
            if (status != napi.napi_ok) return Error.failStatus(status);
            const name = try Napi.from_napi_value_auto_with_allocator(env, tag_raw, []u8, allocator);
            defer allocator.free(name);
            inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |field_name, field_type| {
                if (std.mem.eql(u8, name, field_name)) {
                    var payload_raw: napi.napi_value = null;
                    status = napi.napi_get_named_property(env, raw, payload.ptr, &payload_raw);
                    if (status != napi.napi_ok) return Error.failStatus(status);
                    const converted = try Napi.from_napi_value_auto_with_allocator(env, payload_raw, field_type, allocator);
                    return .{ .value = @unionInit(T, field_name, converted) };
                }
            }
            return Error.failTypeError("Unknown union discriminant '{s}'", .{name});
        }
        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            const object = try Object.Create(Env.from_raw(env));
            try object.Define(tag, @tagName(self.value));
            switch (self.value) {
                inline else => |value| try object.Define(payload, value),
            }
            return object.raw;
        }
        pub fn napi_deinit(self: Self, allocator: std.mem.Allocator) void {
            Napi.deinit_napi_value_with_allocator(T, self.value, allocator);
        }
    };
}
