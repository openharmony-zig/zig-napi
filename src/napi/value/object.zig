const napi = @import("napi-sys").napi_sys;
const Function = @import("./function.zig").Function;
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Number = @import("./number.zig").Number;
const std = @import("std");
const Value = @import("../value.zig").Value;
const Undefined = @import("./undefined.zig").Undefined;
const Null = @import("./null.zig").Null;
const String = @import("./string.zig").String;
const Array = @import("./array.zig").Array;
const helper = @import("../util/helper.zig");
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("../wrapper/error.zig");
const Reference = @import("../wrapper/reference.zig").Reference;
const native_wrap = @import("../wrapper/native_wrap.zig");
const options = @import("../options.zig");

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
                    @field(result, field.name) = Napi.from_napi_value_auto(env, element, field.type);
                }
                return result;
            },
            else => {
                @compileError("Unsupported type: " ++ @typeName(infos));
            },
        }
    }

    pub fn Create(env: Env) !Object {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_object(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return Object.from_raw(env.raw, raw);
    }

    pub fn New(env: Env, obj: anytype) !Object {
        const obj_type = @TypeOf(obj);
        const obj_infos = @typeInfo(obj_type);
        if (obj_infos != .@"struct") {
            @compileError("Object.New only support struct type, Unsupported type: " ++ @typeName(obj_type));
        }

        if (comptime helper.isTuple(obj_type)) {
            @compileError("Object.New does not support tuple type");
        }

        var self = try Object.Create(env);

        const obj_fields = obj_infos.@"struct".fields;

        inline for (obj_fields) |field| {
            const n_value = try Napi.to_napi_value_auto(env.raw, @field(obj, field.name), field.name);
            try self.Set(
                field.name,
                n_value,
            );
        }

        return self;
    }

    fn keyToNapiValue(self: Object, key: []const u8) !napi.napi_value {
        var key_raw: napi.napi_value = undefined;
        const status = napi.napi_create_string_utf8(self.env, key.ptr, key.len, &key_raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return key_raw;
    }

    pub fn Set(self: Object, key: []const u8, value: anytype) !void {
        const key_raw = try self.keyToNapiValue(key);
        const n_value = try Napi.to_napi_value_auto(self.env, value, null);
        const status = napi.napi_set_property(self.env, self.raw, key_raw, n_value);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
    }

    pub fn SetValue(self: Object, key: anytype, value: anytype) !void {
        const key_raw = try Napi.to_napi_value_auto(self.env, key, null);
        const n_value = try Napi.to_napi_value_auto(self.env, value, null);
        const status = napi.napi_set_property(self.env, self.raw, key_raw, n_value);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
    }

    pub fn setValue(self: Object, key: anytype, value: anytype) !void {
        try self.SetValue(key, value);
    }

    pub fn Get(self: Object, key: []const u8, comptime T: type) T {
        const key_raw = self.keyToNapiValue(key) catch @panic("Failed to create object property key");
        var raw: napi.napi_value = undefined;
        _ = napi.napi_get_property(self.env, self.raw, key_raw, &raw);
        return Napi.from_napi_value_auto(self.env, raw, T);
    }

    pub fn GetNamed(self: Object, comptime key: []const u8, comptime T: type) T {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_get_named_property(self.env, self.raw, @ptrCast(key.ptr), &raw);
        return Napi.from_napi_value_auto(self.env, raw, T);
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

    pub fn propertyNames(self: Object) !Array {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_get_property_names(self.env, self.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return Array.from_raw(self.env, raw);
    }

    pub fn isDate(self: Object) bool {
        comptime options.requireNapiVersion(.v5);

        var result: bool = false;
        const status = napi.napi_is_date(self.env, self.raw, &result);
        if (status != napi.napi_ok) {
            NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
            return false;
        }
        return result;
    }

    pub fn dateValue(self: Object) !f64 {
        comptime options.requireNapiVersion(.v5);

        var result: f64 = 0;
        const status = napi.napi_get_date_value(self.env, self.raw, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return result;
    }

    pub fn freeze(self: Object) !Object {
        comptime options.requireNapiVersion(.v8);

        const status = napi.napi_object_freeze(self.env, self.raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return self;
    }

    pub fn seal(self: Object) !Object {
        comptime options.requireNapiVersion(.v8);

        const status = napi.napi_object_seal(self.env, self.raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return self;
    }

    pub fn CreateRef(self: Object) !Reference(Object) {
        return Reference(Object).New(Env.from_raw(self.env), self);
    }

    pub fn Wrap(self: Object, payload: anytype) !void {
        try self.wrap(payload);
    }

    pub fn WrapWithSizeHint(self: Object, payload: anytype, size_hint: usize) !void {
        try self.wrapWithSizeHint(payload, size_hint);
    }

    pub fn wrap(self: Object, payload: anytype) !void {
        try self.wrapWithSizeHint(payload, 0);
    }

    pub fn wrapWithSizeHint(self: Object, payload: anytype, size_hint: usize) !void {
        try native_wrap.wrap(self.env, self.raw, payload, size_hint);
    }

    pub fn Unwrap(self: Object, comptime T: type) !*T {
        return try self.unwrap(T);
    }

    pub fn unwrap(self: Object, comptime T: type) !*T {
        return try native_wrap.unwrap(self.env, self.raw, T);
    }

    pub fn unwrapConst(self: Object, comptime T: type) !*const T {
        return try native_wrap.unwrapConst(self.env, self.raw, T);
    }

    pub fn DropWrapped(self: Object, comptime T: type) !void {
        try self.dropWrapped(T);
    }

    pub fn dropWrapped(self: Object, comptime T: type) !void {
        try native_wrap.dropWrapped(self.env, self.raw, T);
    }

    pub fn matchesWrapped(self: Object, comptime T: type) bool {
        return native_wrap.matches(self.env, self.raw, T);
    }
};
