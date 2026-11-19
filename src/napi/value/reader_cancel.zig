const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Errors = @import("../wrapper/error.zig");
const Value = @import("../value.zig").NapiValue;
const Function = @import("function.zig").Function;
const Object = @import("object.zig").Object;
const String = @import("string.zig").String;
const PromiseOf = @import("protocol.zig").PromiseOf;

/// Only the handle can cross threads. The Promise belongs to the JS environment.
pub const ReaderCancellation = struct {
    handle: ReaderCancelHandle,
    completion: PromiseOf(void),
};

/// Each Clone owns one Close. The first cancel queues reader.cancel(reason).
pub const ReaderCancelHandle = struct {
    state: *State,

    const State = struct {
        allocator: std.mem.Allocator,
        owners: std.atomic.Value(usize) = .init(1),
        lifetime: std.atomic.Value(usize) = .init(2), // owners and TSFN finalizer
        mutex: std.atomic.Mutex = .unlocked,
        dispatcher: napi.napi_threadsafe_function = null,
        deferred: napi.napi_deferred = null,
        requested: bool = false,
        hook: bool = false,

        fn lock(self: *State) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }
        fn drop(self: *State) void {
            if (self.lifetime.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
        }
        fn stop(self: *State, mode: napi.napi_threadsafe_function_release_mode) void {
            self.lock();
            defer self.mutex.unlock();
            if (self.dispatcher) |tsfn| {
                self.dispatcher = null;
                _ = napi.napi_release_threadsafe_function(tsfn, mode);
            }
        }
        fn cleanup(raw: ?*anyopaque) callconv(.c) void {
            const self: *State = @ptrCast(@alignCast(raw.?));
            self.hook = false;
            self.stop(napi.napi_tsfn_abort);
        }
        fn finalize(env: napi.napi_env, raw: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const self: *State = @ptrCast(@alignCast(raw.?));
            if (env != null and self.hook) {
                _ = napi.napi_remove_env_cleanup_hook(env, cleanup, self);
                // Closing an unused handle completes without cancelling the reader.
                var undef: napi.napi_value = null;
                if (self.deferred != null and napi.napi_get_undefined(env, &undef) == napi.napi_ok)
                    _ = napi.napi_resolve_deferred(env, self.deferred, undef);
            }
            self.lock();
            self.dispatcher = null;
            self.mutex.unlock();
            self.drop();
        }
    };

    const Request = struct {
        allocator: std.mem.Allocator,
        reason: ?[]u8,
        fn destroy(self: *Request) void {
            if (self.reason) |text| self.allocator.free(text);
            self.allocator.destroy(self);
        }
    };

    fn dispatch(env: napi.napi_env, callback: napi.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const request: *Request = @ptrCast(@alignCast(data.?));
        defer request.destroy();
        if (env == null or callback == null) return;
        const self: *State = @ptrCast(@alignCast(context.?));
        const deferred = self.deferred;
        self.deferred = null;
        var undef: napi.napi_value = null;
        var arg: napi.napi_value = null;
        var result: napi.napi_value = null;
        var status = napi.napi_get_undefined(env, &undef);
        if (status == napi.napi_ok) {
            arg = undef;
            if (request.reason) |reason| status = napi.napi_create_string_utf8(env, reason.ptr, reason.len, &arg);
        }
        if (status == napi.napi_ok) status = napi.napi_call_function(env, undef, callback, 1, &arg, &result);
        if (status == napi.napi_ok) {
            // Resolving the deferred adopts returned promises and thenables.
            _ = napi.napi_resolve_deferred(env, deferred, result);
        } else {
            if (status != napi.napi_pending_exception or napi.napi_get_and_clear_last_exception(env, &result) != napi.napi_ok) result = undef;
            _ = napi.napi_reject_deferred(env, deferred, result);
        }
    }

    pub fn init(env: Env, reader: Object) !ReaderCancellation {
        comptime @import("../options.zig").requireNapiVersion(.v4);
        const cancel_method = try reader.Get("cancel", Function(struct { Value }, Value));
        const bound = try cancel_method.Bind(reader);
        const name = try String.createUtf8(env, "zig-napi.reader.cancel");
        const allocator = @import("../util/allocator.zig").capture();
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator };
        var status = napi.napi_create_threadsafe_function(env.raw, bound.raw, null, name.raw, 0, 1, state, State.finalize, state, dispatch, &state.dispatcher);
        if (status != napi.napi_ok) {
            allocator.destroy(state);
            return Errors.failStatus(status);
        }
        const handle = ReaderCancelHandle{ .state = state };
        errdefer handle.Close();
        try env.addCleanupHook(State.cleanup, state);
        state.hook = true;
        var promise: napi.napi_value = null;
        status = napi.napi_create_promise(env.raw, &state.deferred, &promise);
        if (status != napi.napi_ok) return Errors.failStatus(status);
        return .{ .handle = handle, .completion = PromiseOf(void).from_raw(env.raw, promise) };
    }

    pub fn Clone(self: ReaderCancelHandle) ReaderCancelHandle {
        _ = self.state.owners.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn Close(self: ReaderCancelHandle) void {
        if (self.state.owners.fetchSub(1, .acq_rel) == 1) {
            self.state.stop(napi.napi_tsfn_release);
            self.state.drop();
        }
    }
    pub fn cancel(self: ReaderCancelHandle, reason: ?[]const u8) !void {
        const state = self.state;
        state.lock();
        defer state.mutex.unlock();
        const tsfn = state.dispatcher orelse return error.EnvironmentClosed;
        if (state.requested) return;
        const request = try state.allocator.create(Request);
        errdefer state.allocator.destroy(request);
        request.* = .{ .allocator = state.allocator, .reason = if (reason) |r| try state.allocator.dupe(u8, r) else null };
        errdefer if (request.reason) |r| state.allocator.free(r);
        const status = napi.napi_call_threadsafe_function(tsfn, request, napi.napi_tsfn_nonblocking);
        if (status != napi.napi_ok) return Errors.failStatus(status);
        state.requested = true;
    }
};
