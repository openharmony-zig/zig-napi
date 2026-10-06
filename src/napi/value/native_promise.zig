const std = @import("std");
const builtin = @import("builtin");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Value = @import("../value.zig").NapiValue;
const Object = @import("object.zig").Object;
const Function = @import("function.zig").Function;
const Napi = @import("../util/napi.zig").Napi;
const Errors = @import("../wrapper/error.zig");
const ErrorSnapshot = @import("../util/async_ownership.zig").ErrorSnapshot;

/// Convert a JS promise on its environment thread, then wait for native data
/// with a cancellable std.Io futex on a native worker. JS handles cannot be
/// captured this way. Clone/Close share ownership of the native result; wait
/// borrows it until Close. One pending waiter is allowed per promise.
pub fn NativePromise(comptime T: type) type {
    return struct {
        state: *State,
        pub const napi_custom = true;
        pub const napi_ts_kind = "promise";
        pub const napi_value_type = T;
        const Self = @This();
        const State = struct {
            allocator: std.mem.Allocator,
            env: napi.napi_env,
            thread: std.Thread.Id,
            owners: std.atomic.Value(usize) = .init(1),
            native_owners: std.atomic.Value(usize) = .init(1),
            dispatcher: napi.napi_threadsafe_function = null,
            released: std.atomic.Value(bool) = .init(false),
            outcome: std.atomic.Value(u32) = .init(0),
            lock: std.atomic.Mutex = .unlocked,
            wait_io: ?std.Io = null,
            value: ?T = null,
            failure: ?ErrorSnapshot = null,
            hook: bool = false,

            fn acquire(self: *@This()) void {
                _ = self.owners.fetchAdd(1, .monotonic);
            }
            fn release(self: *@This()) void {
                if (self.owners.fetchSub(1, .acq_rel) != 1) return;
                const allocator = self.allocator;
                if (self.value) |value| Napi.deinit_napi_value_with_allocator(T, value, allocator);
                if (self.failure) |*failure| failure.deinit();
                allocator.destroy(self);
            }
            fn lockState(self: *@This()) void {
                while (!self.lock.tryLock()) std.atomic.spinLoopHint();
            }
            fn settle(self: *@This(), outcome: u32) void {
                self.lockState();
                self.outcome.store(outcome, .release);
                const io = self.wait_io;
                // Keep the waiter from returning and retiring its Io backend
                // until the wake call has finished using that backend.
                if (io) |waiting_io| std.Io.futexWake(waiting_io, u32, &self.outcome.raw, std.math.maxInt(u32));
                self.lock.unlock();
                if (self.hook) {
                    _ = napi.napi_remove_env_cleanup_hook(self.env, cleanup, self);
                    self.hook = false;
                }
            }
            fn reject(self: *@This(), failure: Errors.Error) void {
                self.failure = ErrorSnapshot.capture(self.allocator, failure);
                self.settle(2);
            }
            fn cleanup(data: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                self.hook = false;
                if (self.outcome.load(.acquire) == 0) self.reject(Errors.Error.withCodeAndMessage("ERR_NAPI_ENV_CLOSED", "Environment closed before the promise settled"));
                self.env = null;
                if (!self.released.swap(true, .acq_rel)) _ = napi.napi_release_threadsafe_function(self.dispatcher, napi.napi_tsfn_abort);
            }
            fn dispose(_: napi.napi_env, _: napi.napi_value, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                if (self.outcome.load(.acquire) == 0) self.reject(Errors.Error.withCodeAndMessage("ERR_NAPI_PROMISE_CLOSED", "Native promise observer was closed"));
            }
            fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                self.released.store(true, .release);
                if (self.hook) {
                    _ = napi.napi_remove_env_cleanup_hook(self.env, cleanup, self);
                    self.hook = false;
                }
                self.env = null;
                self.release();
            }
        };
        const Handle = struct {
            state: *State,
            fn deinit(self: *@This()) void {
                self.state.release();
            }
            fn fulfill(self: *@This(), _: Env, args: struct { Value }) !void {
                if (self.state.outcome.load(.acquire) != 0) return;
                // Validate the complete native shape, including nested handles.
                // The temporary clone proves the shape is safe for worker input.
                const converted = Napi.from_napi_value_auto_with_allocator(self.state.env, args[0].raw, T, self.state.allocator) catch |err| {
                    if (Env.from_raw(self.state.env).isExceptionPending()) _ = Env.from_raw(self.state.env).getAndClearLastException() catch {};
                    self.state.reject(Errors.mapAnyError(err));
                    return;
                };
                const cloned = Napi.clone_napi_value(T, converted, self.state.allocator) catch |err| {
                    Napi.deinit_napi_value_with_allocator(T, converted, self.state.allocator);
                    self.state.reject(Errors.mapAnyError(err));
                    return;
                };
                Napi.deinit_napi_value_with_allocator(T, converted, self.state.allocator);
                self.state.value = cloned;
                self.state.settle(1);
            }
            fn reject(self: *@This(), env: Env, args: struct { Value }) !void {
                if (self.state.outcome.load(.acquire) != 0) return;
                var raw: napi.napi_value = null;
                const status = napi.napi_coerce_to_string(env.raw, args[0].raw, &raw);
                if (status != napi.napi_ok) {
                    if (env.isExceptionPending()) _ = env.getAndClearLastException() catch {};
                    self.state.reject(Errors.Error.withCodeAndMessage("ERR_NAPI_PROMISE_REJECTED", "JavaScript promise rejected"));
                    return;
                }
                const message = Napi.from_napi_value_auto_with_allocator(env.raw, raw, []u8, self.state.allocator) catch {
                    self.state.reject(Errors.Error.withCodeAndMessage("ERR_NAPI_PROMISE_REJECTED", "JavaScript promise rejected"));
                    return;
                };
                defer self.state.allocator.free(message);
                self.state.reject(Errors.Error.withCodeAndMessage("ERR_NAPI_PROMISE_REJECTED", message));
            }
        };
        pub fn fromPromise(env: Env, promise: anytype) !Self {
            if (comptime builtin.cpu.arch.isWasm()) return error.NativeThreadRequired;
            const allocator = @import("../util/allocator.zig").capture();
            const state = try allocator.create(State);
            state.* = .{ .allocator = allocator, .env = env.raw, .thread = std.Thread.getCurrentId() };
            errdefer state.release();
            const name = try @import("string.zig").String.createUtf8(env, "zig-napi.promise.dispose");
            var status = napi.napi_create_threadsafe_function(env.raw, null, null, name.raw, 0, 1, state, State.finalize, state, State.dispose, &state.dispatcher);
            if (status != napi.napi_ok) return Errors.failStatus(status);
            state.acquire(); // dispatcher lifetime
            errdefer {
                if (!state.released.swap(true, .acq_rel)) _ = napi.napi_release_threadsafe_function(state.dispatcher, napi.napi_tsfn_abort);
            }
            status = napi.napi_unref_threadsafe_function(env.raw, state.dispatcher);
            if (status != napi.napi_ok) return Errors.failStatus(status);
            try env.addCleanupHook(State.cleanup, state);
            state.hook = true;
            errdefer {
                _ = env.removeCleanupHook(State.cleanup, state) catch {};
                state.hook = false;
            }
            const Callback = Function(struct { Value }, void);
            state.acquire();
            const fulfill = Callback.NewClosure(env, "promiseFulfilled", Handle{ .state = state }, Handle.fulfill) catch |err| {
                state.release();
                return err;
            };
            state.acquire();
            const reject = Callback.NewClosure(env, "promiseRejected", Handle{ .state = state }, Handle.reject) catch |err| {
                state.release();
                return err;
            };
            const object = Object.from_raw(env.raw, promise.raw);
            const then = try object.Get("then", Function(struct { Callback, Callback }, Value));
            _ = try then.Apply(object, .{ fulfill, reject });
            return .{ .state = state };
        }
        pub fn Clone(self: Self) Self {
            _ = self.state.native_owners.fetchAdd(1, .monotonic);
            self.state.acquire();
            return self;
        }
        pub fn Close(self: Self) void {
            const state = self.state;
            if (state.native_owners.fetchSub(1, .acq_rel) == 1 and !state.released.swap(true, .acq_rel)) {
                _ = napi.napi_call_threadsafe_function(state.dispatcher, null, napi.napi_tsfn_nonblocking);
                _ = napi.napi_release_threadsafe_function(state.dispatcher, napi.napi_tsfn_release);
            }
            state.release();
        }
        pub fn wait(self: Self, io: std.Io) !T {
            if (comptime builtin.cpu.arch.isWasm()) return error.NativeThreadRequired;
            if (self.state.thread == std.Thread.getCurrentId()) return error.WrongEnvironmentThread;
            self.state.lockState();
            if (self.state.wait_io != null and self.state.outcome.load(.acquire) == 0) {
                self.state.lock.unlock();
                return error.ConcurrentPromiseWait;
            }
            self.state.wait_io = io;
            self.state.lock.unlock();
            defer {
                self.state.lockState();
                self.state.wait_io = null;
                self.state.lock.unlock();
            }
            while (self.state.outcome.load(.acquire) == 0) try std.Io.futexWait(io, u32, &self.state.outcome.raw, 0);
            if (self.state.outcome.load(.acquire) == 1) return self.state.value.?;
            Errors.last_error = self.state.failure.?.stored;
            return error.GenericFailure;
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            return @import("protocol.zig").PromiseOf(T).matches_napi_value(env, raw);
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return fromPromise(Env.from_raw(env), Value.from_raw(env, raw));
        }
        pub fn napi_clone(self: Self, _: std.mem.Allocator) !Self {
            return self.Clone();
        }
        pub fn napi_deinit(self: Self, _: std.mem.Allocator) void {
            self.Close();
        }
    };
}
