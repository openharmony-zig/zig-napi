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
    pub const CleanupHook = ?*const fn (?*anyopaque) callconv(.c) void;
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

    pub fn runScript(self: Env, source: []const u8, comptime T: type) !T {
        const script = try String.createUtf8(self, source);
        var result: napi.napi_value = null;
        const status = napi.napi_run_script(self.raw, script.raw, &result);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return @import("./util/napi.zig").Napi.from_napi_value_auto(self.raw, result, T);
    }

    pub fn symbolFor(self: Env, description: []const u8) !@import("value/special.zig").Symbol {
        if (comptime options.selectedNapiVersion().isAtLeast(.v9) and @hasDecl(napi, "node_api_symbol_for")) {
            var result: napi.napi_value = null;
            const status = napi.node_api_symbol_for(self.raw, description.ptr, description.len, &result);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            return @import("value/special.zig").Symbol.from_raw(self.raw, result);
        }
        const global = try self.getGlobal();
        const symbols = Object.from_raw(self.raw, (try global.Get("Symbol", NapiValue)).raw);
        const callback = try symbols.Get("for", @import("value/function.zig").Function(struct { []const u8 }, @import("value/special.zig").Symbol));
        return callback.Apply(symbols, .{description});
    }

    pub fn adjustExternalMemory(self: Env, change: i64) !i64 {
        var total: i64 = 0;
        const status = napi.napi_adjust_external_memory(self.raw, change, &total);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return total;
    }

    /// The host owns one instance-data slot per environment. Replacing existing
    /// data is rejected so its finalizer cannot be silently lost.
    pub fn setInstanceData(self: Env, value: anytype, finalizer: napi.napi_finalize, hint: ?*anyopaque) !void {
        comptime options.requireNapiVersion(.v6);
        var previous: ?*anyopaque = null;
        var status = napi.napi_get_instance_data(self.raw, &previous);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        if (previous != null) return error.InstanceDataAlreadySet;
        status = napi.napi_set_instance_data(self.raw, value, finalizer, hint);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
    }

    pub fn getInstanceData(self: Env, comptime T: type) !?*T {
        comptime options.requireNapiVersion(.v6);
        var result: ?*anyopaque = null;
        const status = napi.napi_get_instance_data(self.raw, &result);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return if (result) |ptr| @ptrCast(@alignCast(ptr)) else null;
    }

    pub fn addCleanupHook(self: Env, callback: CleanupHook, data: ?*anyopaque) !void {
        comptime options.requireNapiVersion(.v3);
        const status = napi.napi_add_env_cleanup_hook(self.raw, callback, data);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
    }

    pub fn removeCleanupHook(self: Env, callback: CleanupHook, data: ?*anyopaque) !void {
        comptime options.requireNapiVersion(.v3);
        const status = napi.napi_remove_env_cleanup_hook(self.raw, callback, data);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
    }

    /// Register a hook that may finish asynchronously. The hook must call
    /// AsyncCleanupHook.remove after its native work has completed.
    pub fn addAsyncCleanupHook(self: Env, callback: napi.napi_async_cleanup_hook, data: ?*anyopaque) !AsyncCleanupHook {
        comptime options.requireNapiVersion(.v8);
        var handle: napi.napi_async_cleanup_hook_handle = null;
        const status = napi.napi_add_async_cleanup_hook(self.raw, callback, data, &handle);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return .{ .raw = handle };
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

/// A hook handle is single-owner. remove consumes that handle and is idempotent
/// on the same wrapper; copying it does not create another registered hook.
pub const AsyncCleanupHook = struct {
    raw: napi.napi_async_cleanup_hook_handle,
    pub fn remove(self: *@This()) !void {
        const handle = self.raw orelse return;
        const status = napi.napi_remove_async_cleanup_hook(handle);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        self.raw = null;
    }
};
