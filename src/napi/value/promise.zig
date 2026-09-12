const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const NapiValue = @import("../value.zig").NapiValue;
const NapiError = @import("../wrapper/error.zig");
const AbortSignal = @import("../abort_signal.zig");
const GlobalAllocator = @import("../util/allocator.zig");

pub const PromiseStatus = enum {
    Pending,
    Resolved,
    Rejected,
};

/// A borrowed promise handle created by JavaScript code.
///
/// A `PromiseValue` only references a JS object; it owns nothing and cannot be
/// settled from native code. Use it for promises that were received from
/// JavaScript, for example as a callback argument.
pub const PromiseValue = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype = napi.napi_object,

    const Self = @This();

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
        return .{ .env = env, .raw = raw };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) Self {
        return from_raw(env, raw);
    }

    pub fn toPromise(self: Self) Promise {
        return Promise.from_raw(self.env, self.raw);
    }
};

/// Settlement state shared by every copy of a created `Promise`.
///
/// `napi_resolve_deferred`/`napi_reject_deferred` release the deferred on
/// success, so the state must never be copied into an independent alias and the
/// deferred must never be used twice. The state lives as long as the JS promise
/// object it was created for and is released by that object's wrap finalizer.
const Capability = struct {
    allocator: std.mem.Allocator,
    deferred: napi.napi_deferred,
    settled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Promise = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,
    /// Non-null only for promises created through `New`; borrowed JS promises
    /// (see `from_raw`) can never be settled from native code.
    capability: ?*Capability = null,

    const Self = @This();

    /// Borrow a JS promise. `Resolve`/`Reject` on the result return an error
    /// instead of touching an unowned deferred.
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
        return .{
            .env = env,
            .raw = raw,
            .type = napi.napi_object,
            .capability = null,
        };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) Self {
        return from_raw(env, raw);
    }

    /// Create a new pending promise and the native capability used to settle it.
    ///
    /// The promise may only be settled through the returned wrapper (or a copy
    /// of it). Every failure is reported instead of leaving an unusable
    /// deferred behind.
    pub fn New(env: Env) !Self {
        var deferred: napi.napi_deferred = null;
        var raw: napi.napi_value = null;

        const create_status = napi.napi_create_promise(env.raw, &deferred, &raw);
        if (create_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
        }
        if (deferred == null or raw == null) {
            // On the OHOS C import `napi_status` and the status constants do not
            // share a signedness, so convert explicitly.
            const generic_failure: napi.napi_status = @intCast(napi.napi_generic_failure);
            return NapiError.Error.fromStatus(NapiError.Status.New(generic_failure));
        }

        const allocator = GlobalAllocator.globalAllocator();
        const capability = try allocator.create(Capability);
        capability.* = .{
            .allocator = allocator,
            .deferred = deferred,
        };

        const wrap_status = napi.napi_wrap(env.raw, raw, @ptrCast(capability), finalizeCapability, null, null);
        if (wrap_status != napi.napi_ok) {
            allocator.destroy(capability);
            return NapiError.Error.fromStatus(NapiError.Status.New(wrap_status));
        }

        return .{
            .env = env.raw,
            .raw = raw,
            .type = napi.napi_object,
            .capability = capability,
        };
    }

    /// True when this wrapper was created by `New` and has not been settled yet.
    pub fn canSettle(self: Self) bool {
        const capability = self.capability orelse return false;
        return !capability.settled.load(.acquire);
    }

    pub fn isBorrowed(self: Self) bool {
        return self.capability == null;
    }

    pub fn status(self: Self) PromiseStatus {
        const capability = self.capability orelse return .Pending;
        return if (capability.settled.load(.acquire)) .Resolved else .Pending;
    }

    /// Settle the promise with `value`.
    ///
    /// Exactly one settlement succeeds, no matter how many copies of the
    /// wrapper exist. A second attempt (or an attempt on a borrowed promise)
    /// fails with a JS error and never touches an already released deferred.
    pub fn Resolve(self: *Self, value: anytype) !void {
        const napi_value = try Napi.to_napi_value(self.env, value, null);
        try self.resolveRaw(napi_value);
    }

    pub fn resolveRaw(self: *Self, napi_value: napi.napi_value) !void {
        const capability = try self.claim();
        const settle_status = napi.napi_resolve_deferred(self.env, capability.deferred, napi_value);
        if (settle_status != napi.napi_ok) {
            capability.settled.store(false, .release);
            return NapiError.Error.fromStatus(NapiError.Status.New(settle_status));
        }
    }

    pub fn Reject(self: *Self, err: NapiError.Error) !void {
        const napi_value = err.to_napi_error(Env.from_raw(self.env));
        try self.rejectRaw(napi_value);
    }

    pub fn RejectAbortError(self: *Self) !void {
        const napi_value = try AbortSignal.abortErrorValue(Env.from_raw(self.env));
        try self.rejectRaw(napi_value);
    }

    pub fn rejectRaw(self: *Self, napi_value: napi.napi_value) !void {
        const capability = try self.claim();
        const settle_status = napi.napi_reject_deferred(self.env, capability.deferred, napi_value);
        if (settle_status != napi.napi_ok) {
            capability.settled.store(false, .release);
            return NapiError.Error.fromStatus(NapiError.Status.New(settle_status));
        }
    }

    fn claim(self: *Self) !*Capability {
        const capability = self.capability orelse {
            NapiError.last_error = NapiError.Error.withCodeAndMessage(
                "ERR_NAPI_PROMISE_NOT_SETTLABLE",
                "This promise was created by JavaScript and cannot be settled from native code",
            );
            return error.GenericFailure;
        };
        if (capability.settled.swap(true, .acq_rel)) {
            NapiError.last_error = NapiError.Error.withCodeAndMessage(
                "ERR_NAPI_PROMISE_ALREADY_SETTLED",
                "This promise has already been settled",
            );
            return error.GenericFailure;
        }
        return capability;
    }
};

fn finalizeCapability(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const raw = data orelse return;
    const capability: *Capability = @ptrCast(@alignCast(raw));
    // Free with the allocator that created the state: the global operation
    // allocator may have been swapped since the promise was created.
    capability.allocator.destroy(capability);
}

test "borrowed promises refuse to settle" {
    var promise = Promise.from_raw(null, null);
    try std.testing.expect(promise.isBorrowed());
    try std.testing.expect(!promise.canSettle());
    try std.testing.expectError(error.GenericFailure, promise.Resolve(@as(i32, 1)));
    try std.testing.expect(NapiError.last_error != null);
    NapiError.clearLastError();
}
