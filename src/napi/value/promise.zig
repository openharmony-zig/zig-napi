const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const NapiValue = @import("../value.zig").NapiValue;
const NapiError = @import("../wrapper/error.zig");

pub const PromiseStatus = enum {
    Pending,
    Resolved,
    Rejected,
};

pub const Promise = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    deferred: napi.napi_deferred,
    type: napi.napi_valuetype,
    status: PromiseStatus,

    const Self = @This();

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Promise {
        return Promise{
            .env = env,
            .raw = raw,
            .type = napi.napi_object,
            .deferred = undefined, // Will be set when creating new promise
            .status = .Pending,
        };
    }

    pub fn New(env: Env) Promise {
        var deferred: napi.napi_deferred = undefined;
        var promise: napi.napi_value = undefined;

        _ = napi.napi_create_promise(env.raw, &deferred, &promise);

        return Promise{
            .env = env.raw,
            .raw = promise,
            .deferred = deferred,
            .type = napi.napi_object,
            .status = .Pending,
        };
    }

    pub fn Resolve(self: *Self, value: anytype) !void {
        const napi_value = try Napi.to_napi_value(self.env, value, null);
        const s = napi.napi_resolve_deferred(self.env, self.deferred, napi_value);
        if (s != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(s));
        }
        self.status = .Resolved;
    }

    pub fn Reject(self: *Self, err: NapiError.Error) !void {
        const napi_value = err.to_napi_error(Env.from_raw(self.env));
        const s = napi.napi_reject_deferred(self.env, self.deferred, napi_value);
        if (s != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(s));
        }
        self.status = .Rejected;
    }
};
