const std = @import("std");
const napi = @import("../../sys/api.zig");
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const NapiValue = @import("../value.zig").NapiValue;

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

    pub fn Resolve(self: *Self, value: anytype) void {
        self.status = .Resolved;
        const napi_value = Napi.to_napi_value(self.env, value);
        _ = napi.napi_resolve_deferred(self.env, self.deferred, napi_value);
    }

    pub fn Reject(self: *Self, reason: anytype) void {
        self.status = .Rejected;
        const napi_value = Napi.to_napi_value(self.env, reason);
        _ = napi.napi_reject_deferred(self.env, self.deferred, napi_value);
    }
};
