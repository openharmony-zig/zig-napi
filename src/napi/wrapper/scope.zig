const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiValue = @import("../value.zig").NapiValue;
const Error = @import("error.zig");

pub const HandleScope = struct {
    env: napi.napi_env,
    raw: napi.napi_handle_scope,

    pub fn open(env: Env) !HandleScope {
        var raw: napi.napi_handle_scope = null;
        const status = napi.napi_open_handle_scope(env.raw, &raw);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return .{ .env = env.raw, .raw = raw };
    }

    pub fn close(self: *HandleScope) !void {
        if (self.raw == null) return error.ScopeClosed;
        const status = napi.napi_close_handle_scope(self.env, self.raw);
        if (status != napi.napi_ok) return Error.failStatus(status);
        self.raw = null;
    }
};

pub const EscapableHandleScope = struct {
    env: napi.napi_env,
    raw: napi.napi_escapable_handle_scope,

    pub fn open(env: Env) !EscapableHandleScope {
        var raw: napi.napi_escapable_handle_scope = null;
        const status = napi.napi_open_escapable_handle_scope(env.raw, &raw);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return .{ .env = env.raw, .raw = raw };
    }

    pub fn escape(self: EscapableHandleScope, value: anytype) !NapiValue {
        if (self.raw == null) return error.ScopeClosed;
        var result: napi.napi_value = null;
        const status = napi.napi_escape_handle(self.env, self.raw, value.raw, &result);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return NapiValue.from_raw(self.env, result);
    }

    pub fn close(self: *EscapableHandleScope) !void {
        if (self.raw == null) return error.ScopeClosed;
        const status = napi.napi_close_escapable_handle_scope(self.env, self.raw);
        if (status != napi.napi_ok) return Error.failStatus(status);
        self.raw = null;
    }
};
