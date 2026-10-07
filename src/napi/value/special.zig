const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const Error = @import("../wrapper/error.zig");

pub const Date = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    pub const napi_custom = true;
    pub const napi_ts_type = "Date";
    pub fn New(env: Env, milliseconds: f64) !Date {
        return from_raw(env.raw, (try env.createDate(milliseconds)).raw);
    }
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Date {
        return .{ .env = env, .raw = raw };
    }
    pub fn value(self: Date) !f64 {
        var result: f64 = 0;
        const status = napi.napi_get_date_value(self.env, self.raw, &result);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return result;
    }
    pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
        var result = false;
        const status = napi.napi_is_date(env, raw, &result);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return result;
    }
    pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Date {
        return from_raw(env, raw);
    }
    pub fn to_napi_value(self: Date, _: napi.napi_env) !napi.napi_value {
        return self.raw;
    }
};

pub const Symbol = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    pub const napi_custom = true;
    pub const napi_ts_type = "symbol";
    pub fn New(env: Env, description: []const u8) !Symbol {
        return from_raw(env.raw, (try env.createSymbol(description)).raw);
    }
    pub fn forKey(env: Env, description: []const u8) !Symbol {
        return from_raw(env.raw, (try env.symbolFor(description)).raw);
    }
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Symbol {
        return .{ .env = env, .raw = raw };
    }
    pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
        var kind: napi.napi_valuetype = undefined;
        const status = napi.napi_typeof(env, raw, &kind);
        if (status != napi.napi_ok) return Error.failStatus(status);
        return kind == napi.napi_symbol;
    }
    pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Symbol {
        return from_raw(env, raw);
    }
    pub fn to_napi_value(self: Symbol, _: napi.napi_env) !napi.napi_value {
        return self.raw;
    }
};

/// Inject the callback receiver without consuming a positional argument.
pub fn This(comptime T: type) type {
    return struct {
        value: T,
        pub const napi_this = true;
        pub const napi_custom = true;
        pub const napi_ts_kind = "reference";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn matches_napi_value(_: napi.napi_env, _: napi.napi_value) !bool {
            return true;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, allocator: std.mem.Allocator) !Self {
            return .{ .value = try Napi.from_napi_value_auto_with_allocator(env, raw, T, allocator) };
        }
        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            return Napi.to_napi_value_auto(env, self.value, null);
        }
        pub fn napi_deinit(self: Self, allocator: std.mem.Allocator) void {
            Napi.deinit_napi_value_with_allocator(T, self.value, allocator);
        }
    };
}
