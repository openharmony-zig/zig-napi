const std = @import("std");
const napi = @import("napi-sys");
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const ArrayList = std.ArrayList;
const NapiError = @import("../wrapper/error.zig");

pub const Array = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    len: u32,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Array {
        // TODO: check if the value is an array
        var len: u32 = 0;
        _ = napi.napi_get_array_length(env, raw, &len);
        return Array{ .env = env, .raw = raw, .len = len, .type = napi.napi_object };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);

        switch (infos) {
            .array => {
                const array_len = infos.array.len;

                for (0..array_len) |i| {
                    var element: napi.napi_value = undefined;
                    _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                    T[i] = Napi.from_napi_value(env, element, infos.array.child);
                }

                return T;
            },
            .pointer => {
                if (comptime helper.isSlice(T)) {
                    // TODO: check if the value is an array
                    var len: u32 = undefined;
                    _ = napi.napi_get_array_length(env, raw, &len);

                    const allocator = std.heap.page_allocator;
                    const buf = allocator.alloc(infos.pointer.child, len) catch @panic("OOM");

                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        buf[i] = Napi.from_napi_value(env, element, infos.pointer.child);
                    }
                    return buf;
                }
                @compileError("Only support slice type, Unsupported type: " ++ @typeName(T));
            },
            .@"struct" => {
                if (comptime helper.isTuple(T)) {
                    var result: T = undefined;

                    inline for (infos.@"struct".fields, 0..) |field, i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        @field(result, field.name) = Napi.from_napi_value(env, element, field.type);
                    }
                    return result;
                }
                if (comptime helper.isGenericType(T, "ArrayList")) {
                    // Get Array List's items type
                    const child = comptime helper.getArrayListElementType(T);

                    var result: T = ArrayList(child).init(std.heap.page_allocator);
                    var len: u32 = undefined;
                    _ = napi.napi_get_array_length(env, raw, &len);
                    result.ensureTotalCapacity(len) catch @panic("OOM");
                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        result.append(Napi.from_napi_value(env, element, child)) catch @panic("OOM");
                    }
                    return result;
                }
                @compileError("Only support array, slice, and tuple type, Unsupported type: " ++ @typeName(T));
            },
            else => {
                @compileError("Only support array, slice, and tuple type, Unsupported type: " ++ @typeName(infos));
            },
        }
    }

    pub fn New(env: Env, array: anytype) !Array {
        const array_type = @TypeOf(array);
        const infos = @typeInfo(array_type);

        if (infos != .array and (comptime !helper.isSlice(array_type)) and (comptime !helper.isTuple(array_type)) and (comptime !helper.isGenericType(array_type, "ArrayList"))) {
            @compileError("Array.New only support array,ArrayList,slice or tuple type, Unsupported type: " ++ @typeName(array_type));
        }
        var len: u32 = undefined;
        if (infos == .array) {
            len = infos.array.len;
        } else if (comptime helper.isSlice(array_type)) {
            len = @intCast(array.len);
        } else if (comptime helper.isTuple(array_type)) {
            len = infos.@"struct".fields.len;
        } else if (comptime helper.isGenericType(array_type, "ArrayList")) {
            len = @intCast(array.capacity);
        }

        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_array(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        if (infos == .array or comptime helper.isSlice(array_type)) {
            for (array, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value(env.raw, item, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isTuple(array_type)) {
            inline for (infos.@"struct".fields, 0..) |item, i| {
                const value = @field(array, item.name);
                const napi_value = try Napi.to_napi_value(env.raw, value, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isGenericType(array_type, "ArrayList")) {
            for (array.items, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value(env.raw, item, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        }

        return Array{
            .env = env.raw,
            .raw = raw,
            .len = len,
            .type = napi.napi_object,
        };
    }
};
