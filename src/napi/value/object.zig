const napi = @import("../../sys/api.zig");
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

    pub fn Set(self: Object, comptime key: []const u8, value: anytype) void {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        switch (value_type) {
            Number, Object, Undefined, Null, String => {
                const napi_desc = [_]napi.napi_property_descriptor{
                    .{
                        .utf8name = @ptrCast(key.ptr),
                        .method = null,
                        .getter = null,
                        .setter = null,
                        .value = value.raw,
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
                switch (infos) {
                    .@"fn" => {
                        const FnImpl = Function.New(Env.from_raw(self.env), key, value);

                        const desc = [_]napi.napi_property_descriptor{
                            .{
                                .utf8name = @ptrCast(key.ptr),
                                .method = FnImpl.inner_fn,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = napi.napi_default,
                                .data = null,
                            },
                        };
                        const status = napi.napi_define_properties(self.env, self.raw, 1, &desc);
                        if (status != napi.napi_ok) {
                            @panic("Failed to define properties");
                        }
                    },
                    else => {},
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
                return Napi.to_napi_value(self.env, key);
            },
        }
    }

    pub fn Has(self: Object, comptime key: []const u8) bool {
        var result: bool = false;
        _ = napi.napi_has_property(self.env, self.raw, @ptrCast(key.ptr), &result);
        return result;
    }
};
