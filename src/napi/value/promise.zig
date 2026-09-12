const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const NapiValue = @import("../value.zig").NapiValue;
const NapiError = @import("../wrapper/error.zig");
const AbortSignal = @import("../abort_signal.zig");
const Undefined = @import("../value/undefined.zig").Undefined;
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

/// Settlement state of a created promise, shared by every copy of the wrapper.
///
/// `napi_resolve_deferred`/`napi_reject_deferred` release the deferred on
/// success, so the state must never be copied into an independent alias and the
/// deferred must never be used twice. The state lives as long as the JS promise
/// object it was created for and is released by that object's wrap finalizer.
const Capability = struct {
    allocator: std.mem.Allocator,
    deferred: napi.napi_deferred,
    outcome: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Outcome.pending)),

    fn claim(self: *Capability) bool {
        return self.outcome.cmpxchgStrong(
            @intFromEnum(Outcome.pending),
            @intFromEnum(Outcome.claimed),
            .acq_rel,
            .acquire,
        ) == null;
    }

    fn releaseClaim(self: *Capability) void {
        self.outcome.store(@intFromEnum(Outcome.pending), .release);
    }

    fn mark(self: *Capability, outcome: Outcome) void {
        self.outcome.store(@intFromEnum(outcome), .release);
    }
};

/// Settlement outcome. `claimed` is the transient state between winning a
/// settlement attempt and the N-API call that completes it; it protects the
/// deferred from a second (possibly concurrent) attempt.
const Outcome = enum(u8) {
    pending,
    claimed,
    resolved,
    rejected,
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
        const allocator = GlobalAllocator.capture();
        // The settlement state is allocated before the promise exists, so a
        // failed allocation cannot orphan a deferred (a deferred keeps its
        // promise alive until it is resolved or rejected).
        const capability = try allocator.create(Capability);

        var deferred: napi.napi_deferred = null;
        var raw: napi.napi_value = null;
        const create_status = napi.napi_create_promise(env.raw, &deferred, &raw);
        if (create_status != napi.napi_ok) {
            allocator.destroy(capability);
            return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
        }
        if (deferred == null or raw == null) {
            // On the OHOS C import `napi_status` and the status constants do not
            // share a signedness, so convert explicitly.
            const generic_failure: napi.napi_status = @intCast(napi.napi_generic_failure);
            allocator.destroy(capability);
            return NapiError.Error.fromStatus(NapiError.Status.New(generic_failure));
        }
        capability.* = .{
            .allocator = allocator,
            .deferred = deferred,
        };

        const wrap_status = napi.napi_wrap(env.raw, raw, @ptrCast(capability), finalizeCapability, null, null);
        if (wrap_status != napi.napi_ok) {
            // Without the wrap there is no finalizer to release the state, and
            // the only way to release the deferred is to settle it. Resolve it
            // with `undefined` so the never-handed-out promise is reclaimed
            // silently instead of becoming an unhandled rejection.
            releaseDeferredQuietly(env, deferred);
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
        return self.outcomeOf(capability) == .pending;
    }

    pub fn isBorrowed(self: Self) bool {
        return self.capability == null;
    }

    /// Outcome recorded by the settlement that won, shared by every copy.
    pub fn status(self: Self) PromiseStatus {
        const capability = self.capability orelse return .Pending;
        return switch (self.outcomeOf(capability)) {
            .pending, .claimed => .Pending,
            .resolved => .Resolved,
            .rejected => .Rejected,
        };
    }

    fn outcomeOf(_: Self, capability: *Capability) Outcome {
        return @enumFromInt(capability.outcome.load(.acquire));
    }

    /// Size of the native settlement state a created promise keeps alive until
    /// its JavaScript object is collected (diagnostics/tests only).
    pub fn settlementStateSize() usize {
        return @sizeOf(Capability);
    }

    /// Settle the promise with `value`.
    ///
    /// Exactly one settlement succeeds, no matter how many copies of the
    /// wrapper exist. A second attempt (or an attempt on a borrowed promise)
    /// fails with a JS error and never touches an already released deferred.
    pub fn Resolve(self: *Self, value: anytype) !void {
        // Claim before converting: a borrowed or already settled promise must
        // not build a JavaScript value (or run conversion side effects) on the
        // way to failing.
        const capability = try self.claim();
        const napi_value = Napi.to_napi_value(self.env, value, null) catch |err| {
            capability.releaseClaim();
            return err;
        };
        try self.resolveClaimed(capability, napi_value);
    }

    pub fn resolveRaw(self: *Self, napi_value: napi.napi_value) !void {
        const capability = try self.claim();
        try self.resolveClaimed(capability, napi_value);
    }

    pub fn Reject(self: *Self, err: NapiError.Error) !void {
        const capability = try self.claim();
        const napi_value = err.to_napi_error(Env.from_raw(self.env));
        try self.rejectClaimed(capability, napi_value);
    }

    pub fn RejectAbortError(self: *Self) !void {
        const capability = try self.claim();
        const napi_value = AbortSignal.abortErrorValue(Env.from_raw(self.env)) catch |err| {
            capability.releaseClaim();
            return err;
        };
        try self.rejectClaimed(capability, napi_value);
    }

    pub fn rejectRaw(self: *Self, napi_value: napi.napi_value) !void {
        const capability = try self.claim();
        try self.rejectClaimed(capability, napi_value);
    }

    /// Settle a promise that is never handed to JavaScript (a setup failure
    /// after the promise was created) so its deferred is released without
    /// producing an unhandled rejection.
    ///
    /// Best effort: failures are ignored, there is nothing left to report to.
    pub fn discard(self: *Self) void {
        const capability = self.claim() catch return;
        const undefined_value = Undefined.New(Env.from_raw(self.env));
        self.resolveClaimed(capability, undefined_value.raw) catch {};
    }

    fn resolveClaimed(self: *Self, capability: *Capability, napi_value: napi.napi_value) !void {
        const settle_status = napi.napi_resolve_deferred(self.env, capability.deferred, napi_value);
        if (settle_status != napi.napi_ok) {
            capability.releaseClaim();
            return NapiError.Error.fromStatus(NapiError.Status.New(settle_status));
        }
        capability.mark(.resolved);
    }

    fn rejectClaimed(self: *Self, capability: *Capability, napi_value: napi.napi_value) !void {
        const settle_status = napi.napi_reject_deferred(self.env, capability.deferred, napi_value);
        if (settle_status != napi.napi_ok) {
            capability.releaseClaim();
            return NapiError.Error.fromStatus(NapiError.Status.New(settle_status));
        }
        capability.mark(.rejected);
    }

    fn claim(self: *Self) !*Capability {
        const capability = self.capability orelse {
            NapiError.last_error = NapiError.Error.withCodeAndMessage(
                "ERR_NAPI_PROMISE_NOT_SETTLABLE",
                "This promise was created by JavaScript and cannot be settled from native code",
            );
            return error.GenericFailure;
        };
        if (!capability.claim()) {
            NapiError.last_error = NapiError.Error.withCodeAndMessage(
                "ERR_NAPI_PROMISE_ALREADY_SETTLED",
                "This promise has already been settled",
            );
            return error.GenericFailure;
        }
        return capability;
    }
};

/// Release a deferred that no wrapper will ever settle.
fn releaseDeferredQuietly(env: Env, deferred: napi.napi_deferred) void {
    const undefined_value = Undefined.New(env);
    _ = napi.napi_resolve_deferred(env.raw, deferred, undefined_value.raw);
}

fn finalizeCapability(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const raw = data orelse return;
    const capability: *Capability = @ptrCast(@alignCast(raw));
    // Free with the allocator that created the state: the global operation
    // allocator may have been swapped since the promise was created.
    capability.allocator.destroy(capability);
}

test "borrowed promises refuse to claim a settlement" {
    // `claim` is exercised directly: `Resolve` would need a live environment and
    // pull the N-API entry points into the unit test binary.
    var promise = Promise.from_raw(null, null);
    try std.testing.expect(promise.isBorrowed());
    try std.testing.expect(!promise.canSettle());
    try std.testing.expectError(error.GenericFailure, promise.claim());
    try std.testing.expect(NapiError.last_error != null);
    NapiError.clearLastError();
}

test "settlement claims are exclusive and released on failure" {
    var capability = Capability{ .allocator = std.testing.allocator, .deferred = null };
    var promise = Promise{ .env = null, .raw = null, .type = napi.napi_object, .capability = &capability };

    try std.testing.expect(promise.claim() != error.GenericFailure);
    // A second claim (a copy, another thread) must fail while the first is held.
    var copy = promise;
    try std.testing.expectError(error.GenericFailure, copy.claim());
    NapiError.clearLastError();

    capability.releaseClaim();
    try std.testing.expect(promise.canSettle());
}

test "status reflects the outcome recorded by the winner and is shared by aliases" {
    var capability = Capability{ .allocator = std.testing.allocator, .deferred = null };
    var promise = Promise{ .env = null, .raw = null, .type = napi.napi_object, .capability = &capability };
    var alias = promise;

    try std.testing.expectEqual(PromiseStatus.Pending, promise.status());
    capability.mark(.rejected);
    try std.testing.expectEqual(PromiseStatus.Rejected, promise.status());
    try std.testing.expectEqual(PromiseStatus.Rejected, alias.status());
    try std.testing.expect(!alias.canSettle());

    capability.mark(.resolved);
    try std.testing.expectEqual(PromiseStatus.Resolved, alias.status());
}
