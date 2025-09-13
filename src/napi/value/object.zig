const napi = @import("napi-sys");
const Function = @import("./function.zig").Function;
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Number = @import("./number.zig").Number;
const std = @import("std");
const Value = @import("../value.zig").Value;
const Undefined = @import("./undefined.zig").Undefined;
const Null = @import("./null.zig").Null;
const String = @import("./string.zig").String;
const helper = @import("../util/helper.zig");
const Napi = @import("../util/napi.zig").Napi;

pub const Object = struct {
    env: napi.napi_env,
    raw: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Object {
        return Object{
            .env = env,
            .raw = raw,
        };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        switch (infos) {
            .@"struct" => {
                if (comptime helper.isTuple(T)) {
                    @compileError("Object does not support tuple type");
                }

                var result: T = undefined;
                inline for (infos.@"struct".fields) |field| {
                    var element: napi.napi_value = undefined;
                    _ = napi.napi_get_named_property(env, raw, @ptrCast(field.name.ptr), &element);
                    @field(result, field.name) = Napi.from_napi_value(env, element, field.type);
                }
                return result;
            },
            else => {
                @compileError("Unsupported type: " ++ @typeName(infos));
            },
        }
    }

    pub fn New(env: Env, obj: anytype) Object {
        const obj_type = @TypeOf(obj);
        const obj_infos = @typeInfo(obj_type);
        if (obj_infos != .@"struct") {
            @compileError("Object.New only support struct type, Unsupported type: " ++ @typeName(obj_type));
        }

        if (comptime helper.isTuple(obj_type)) {
            @compileError("Object.New does not support tuple type");
        }

        var raw: napi.napi_value = undefined;
        _ = napi.napi_create_object(env.raw, &raw);

        var self = Object.from_raw(env.raw, raw);

        const obj_fields = obj_infos.@"struct".fields;

        inline for (obj_fields) |field| {
            self.Set(field.name, Napi.to_napi_value(env.raw, @field(obj, field.name)));
        }

        return self;
    }

    pub fn Set(self: Object, comptime key: []const u8, value: anytype) void {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        switch (infos) {
            .@"fn" => {
                const fn_impl = Function.New(Env.from_raw(self.env), key, value);
                const napi_desc = [_]napi.napi_property_descriptor{
                    .{
                        .utf8name = @ptrCast(key.ptr),
                        .method = fn_impl.inner_fn,
                        .getter = null,
                        .setter = null,
                        .value = null,
                        .attributes = napi.napi_default,
                        .data = null,
                    },
                };
                const status = napi.napi_define_properties(self.env, self.raw, 1, &napi_desc);
                if (status != napi.napi_ok) {
                    @panic("Failed to define properties");
                }
            },
            else => {
                const n_value = Napi.to_napi_value(self.env, value);
                const napi_desc = [_]napi.napi_property_descriptor{
                    .{
                        .utf8name = @ptrCast(key.ptr),
                        .method = null,
                        .getter = null,
                        .setter = null,
                        .value = n_value,
                        .attributes = napi.napi_default,
                        .data = null,
                    },
                };
                const status = napi.napi_define_properties(self.env, self.raw, 1, &napi_desc);
                if (status != napi.napi_ok) {
                    @panic("Failed to define properties");
                }
            },
        }
    }

    /// Get a property from the object
    /// If key is []u8 or likely, key will marked as a string, it will try to get a named property
    /// Otherwise, key will be marked as a NapiValue and get a property by napi_get_property
    pub fn Get(self: Object, comptime key: type, comptime T: type) T {
        const is_string = helper.isString(key);

        switch (is_string) {
            .true => {
                var raw: napi.napi_value = undefined;
                _ = napi.napi_get_named_property(self.env, self.raw, @ptrCast(key.ptr), &raw);
                return Value.from_raw(self.env, raw);
            },
            .false => {
                return Napi.ToNapiValue(self.env, key);
            },
        }
    }

    /// Check if the object has a property
    /// If key is []u8 or likely, key will marked as a string, it will try to get a named property
    /// Otherwise, key will be marked as a NapiValue and check a property by napi_has_property
    pub fn Has(self: Object, comptime key: []const u8) bool {
        var result: bool = false;

        const is_string = helper.isString(key);
        switch (is_string) {
            .true => {
                _ = napi.napi_has_named_property(self.env, self.raw, @ptrCast(key.ptr), &result);
            },
            .false => {
                _ = napi.napi_has_property(self.env, self.raw, @ptrCast(key.ptr), &result);
            },
        }
        return result;
    }
};
