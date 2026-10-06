const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const builtin = @import("builtin");
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const Error = @import("error.zig");
const Allocator = @import("../util/allocator.zig");

/// Explicit shared ownership. Clone creates another owner; copying this value
/// alone does not. Get runs on the environment thread; Clone/Close may run
/// on native threads. Last-owner disposal is dispatched through an unreferenced
/// TSFN before deleting engine references. Environment cleanup
/// invalidates surviving owners before the engine destroys its references.
pub fn ManagedReference(comptime T: type, comptime strong: bool) type {
    return struct {
        owner: *Owner,
        pub const napi_custom = true;
        pub const napi_ts_type = "unknown";
        pub const napi_ts_kind = "reference";
        pub const napi_value_type = T;
        const Self = @This();
        const Owner = struct {
            env: napi.napi_env,
            reference: napi.napi_ref,
            dispatcher: napi.napi_threadsafe_function = null,
            allocator: std.mem.Allocator,
            thread: std.Thread.Id,
            owners: std.atomic.Value(usize) = .init(1),
            lifetime: std.atomic.Value(usize) = .init(2), // owner group and engine
            closed: std.atomic.Value(bool) = .init(false),
            released: std.atomic.Value(bool) = .init(false),
            fn dropLifetime(owner: *@This()) void {
                if (owner.lifetime.fetchSub(1, .acq_rel) == 1) owner.allocator.destroy(owner);
            }
            fn deleteReference(owner: *@This(), remove_hook: bool) void {
                owner.closed.store(true, .release);
                if (owner.env == null) return;
                if (remove_hook) _ = napi.napi_remove_env_cleanup_hook(owner.env, cleanup, owner);
                if (owner.reference != null) _ = napi.napi_delete_reference(owner.env, owner.reference);
                owner.reference = null;
                owner.env = null;
            }
            fn cleanup(data: ?*anyopaque) callconv(.c) void {
                const owner: *@This() = @ptrCast(@alignCast(data.?));
                owner.deleteReference(false);
                if (!owner.released.swap(true, .acq_rel)) _ = napi.napi_release_threadsafe_function(owner.dispatcher, napi.napi_tsfn_abort);
            }
            fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const owner: *@This() = @ptrCast(@alignCast(data.?));
                owner.released.store(true, .release);
                owner.deleteReference(true);
                owner.dropLifetime();
            }
            fn dispose(_: napi.napi_env, _: napi.napi_value, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const owner: *@This() = @ptrCast(@alignCast(context.?));
                owner.deleteReference(true);
            }
        };
        pub fn New(env: Env, value: T) !Self {
            comptime @import("../options.zig").requireNapiVersion(.v4);
            const name = try @import("../value/string.zig").String.createUtf8(env, "zig-napi.reference.dispose");
            const allocator = Allocator.capture();
            const owner = try allocator.create(Owner);
            owner.* = .{ .env = env.raw, .reference = null, .allocator = allocator, .thread = if (builtin.cpu.arch.isWasm()) 0 else std.Thread.getCurrentId() };
            var status = napi.napi_create_reference(env.raw, value.raw, if (strong) 1 else 0, &owner.reference);
            if (status != napi.napi_ok) {
                allocator.destroy(owner);
                return Error.failStatus(status);
            }
            status = napi.napi_create_threadsafe_function(env.raw, null, null, name.raw, 0, 1, owner, Owner.finalize, owner, Owner.dispose, &owner.dispatcher);
            if (status != napi.napi_ok) {
                _ = napi.napi_delete_reference(env.raw, owner.reference);
                allocator.destroy(owner);
                return Error.failStatus(status);
            }
            status = napi.napi_add_env_cleanup_hook(env.raw, Owner.cleanup, owner);
            if (status != napi.napi_ok) {
                owner.deleteReference(false);
                _ = napi.napi_release_threadsafe_function(owner.dispatcher, napi.napi_tsfn_abort);
                owner.dropLifetime();
                return Error.failStatus(status);
            }
            status = napi.napi_unref_threadsafe_function(env.raw, owner.dispatcher);
            if (status != napi.napi_ok) {
                owner.deleteReference(true);
                _ = napi.napi_release_threadsafe_function(owner.dispatcher, napi.napi_tsfn_abort);
                owner.dropLifetime();
                return Error.failStatus(status);
            }
            return .{ .owner = owner };
        }
        pub fn Clone(self: Self) !Self {
            if (self.owner.closed.load(.acquire)) return error.EnvironmentClosed;
            var current = self.owner.owners.load(.monotonic);
            while (true) {
                const next = try std.math.add(usize, current, 1);
                current = self.owner.owners.cmpxchgWeak(current, next, .monotonic, .monotonic) orelse return self;
            }
        }
        pub fn Get(self: Self) !?T {
            if (!builtin.cpu.arch.isWasm() and self.owner.thread != std.Thread.getCurrentId()) return error.WrongEnvironmentThread;
            if (self.owner.closed.load(.acquire)) return error.EnvironmentClosed;
            var raw: napi.napi_value = null;
            const status = napi.napi_get_reference_value(self.owner.env, self.owner.reference, &raw);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return if (raw == null) null else try Napi.from_napi_value_auto(self.owner.env, raw, T);
        }
        pub fn GetValue(self: Self) !T {
            return (try self.Get()) orelse error.ReferenceCollected;
        }
        pub fn Close(self: Self) void {
            const owner = self.owner;
            if (owner.owners.fetchSub(1, .acq_rel) != 1) return;
            if (!owner.released.swap(true, .acq_rel)) {
                _ = napi.napi_call_threadsafe_function(owner.dispatcher, null, napi.napi_tsfn_nonblocking);
                _ = napi.napi_release_threadsafe_function(owner.dispatcher, napi.napi_tsfn_release);
            }
            owner.dropLifetime();
        }
        pub fn upgrade(self: Self) !?ManagedReference(T, true) {
            const value = (try self.Get()) orelse return null;
            return try ManagedReference(T, true).New(Env.from_raw(self.owner.env), value);
        }
        pub fn downgrade(self: Self) !ManagedReference(T, false) {
            return ManagedReference(T, false).New(Env.from_raw(self.owner.env), try self.GetValue());
        }
        pub fn matches_napi_value(_: napi.napi_env, _: napi.napi_value) !bool {
            return true;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return New(Env.from_raw(env), try Napi.from_napi_value_auto(env, raw, T));
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return (try self.GetValue()).raw;
        }
        pub fn napi_clone(self: Self, _: std.mem.Allocator) !Self {
            return self.Clone();
        }
        pub fn napi_deinit(self: Self, _: std.mem.Allocator) void {
            self.Close();
        }
    };
}
