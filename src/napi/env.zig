const napi = @import("napi-sys").napi_sys;
const Undefined = @import("./value/undefined.zig").Undefined;
const Null = @import("./value/null.zig").Null;
const Object = @import("./value/object.zig").Object;
const String = @import("./value/string.zig").String;
const NapiValue = @import("./value.zig").NapiValue;
const NapiError = @import("./wrapper/error.zig");
const native_wrap = @import("./wrapper/native_wrap.zig");
const options = @import("./options.zig");

pub const Env = struct {
    raw: napi.napi_env,

    pub fn from_raw(raw: napi.napi_env) Env {
        return Env{
            .raw = raw,
        };
    }

    pub fn getUndefined(self: Env) Undefined {
        var result: napi.napi_value = undefined;
        _ = napi.napi_get_undefined(self.raw, &result);
        return Undefined.from_raw(self.raw, result);
    }

    pub fn getNull(self: Env) Null {
        var result: napi.napi_value = undefined;
        _ = napi.napi_get_null(self.raw, &result);
        return Null.from_raw(self.raw, result);
    }

    pub fn getNapiVersion(self: Env) u32 {
        var result: u32 = 0;
        _ = napi.napi_get_version(self.raw, &result);
        return result;
    }

    pub fn getGlobal(self: Env) !Object {
        var result: napi.napi_value = undefined;
        const status = napi.napi_get_global(self.raw, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return Object.from_raw(self.raw, result);
    }

    pub fn createSymbol(self: Env, description: []const u8) !NapiValue {
        const description_value = String.New(self, description);
        var result: napi.napi_value = undefined;
        const status = napi.napi_create_symbol(self.raw, description_value.raw, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return NapiValue.from_raw(self.raw, result);
    }

    pub fn createDate(self: Env, value: f64) !Object {
        comptime options.requireNapiVersion(.v5);

        var result: napi.napi_value = undefined;
        const status = napi.napi_create_date(self.raw, value, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return Object.from_raw(self.raw, result);
    }

    pub fn isExceptionPending(self: Env) bool {
        var result = false;
        _ = napi.napi_is_exception_pending(self.raw, &result);
        return result;
    }

    pub fn getAndClearLastException(self: Env) !NapiValue {
        var result: napi.napi_value = undefined;
        const status = napi.napi_get_and_clear_last_exception(self.raw, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return NapiValue.from_raw(self.raw, result);
    }

    pub fn wrap(self: Env, js_object: anytype, payload: anytype) !void {
        return self.wrapWithSizeHint(js_object, payload, 0);
    }

    pub fn wrapWithSizeHint(self: Env, js_object: anytype, payload: anytype, size_hint: usize) !void {
        try native_wrap.wrap(self.raw, objectRaw(js_object), payload, size_hint);
    }

    pub fn unwrap(self: Env, js_object: anytype, comptime T: type) !*T {
        return try native_wrap.unwrap(self.raw, objectRaw(js_object), T);
    }

    pub fn unwrapConst(self: Env, js_object: anytype, comptime T: type) !*const T {
        return try native_wrap.unwrapConst(self.raw, objectRaw(js_object), T);
    }

    pub fn dropWrapped(self: Env, js_object: anytype, comptime T: type) !void {
        try native_wrap.dropWrapped(self.raw, objectRaw(js_object), T);
    }

    pub fn matchesWrapped(self: Env, js_object: anytype, comptime T: type) bool {
        return native_wrap.matches(self.raw, objectRaw(js_object), T);
    }
};

fn objectRaw(js_object: anytype) napi.napi_value {
    const ObjectType = @TypeOf(js_object);
    const ValueType = switch (@typeInfo(ObjectType)) {
        .pointer => |ptr| ptr.child,
        else => ObjectType,
    };
    if (!@hasField(ValueType, "raw")) {
        @compileError("Expected an object-like value with a raw napi_value field, got: " ++ @typeName(ObjectType));
    }
    return js_object.raw;
}
