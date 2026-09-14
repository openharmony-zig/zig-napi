const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("./env.zig").Env;
const String = @import("./value/string.zig").String;
const Undefined = @import("./value/undefined.zig").Undefined;
const NapiError = @import("./wrapper/error.zig");
const GlobalAllocator = @import("./util/allocator.zig");

pub const AbortCallback = *const fn (?*anyopaque) void;

/// Owner of the context an abort callback receives.
///
/// `retain`/`release` bracket a single callback invocation so the context
/// (usually an async operation) cannot be destroyed while its abort callback is
/// running: `deactivate` marks the registration inactive under the same mutex,
/// which makes the pair a two-way handshake - either the callback takes its
/// reference first and the owner waits for it, or the callback observes the
/// inactive registration and never runs.
pub const ContextOwner = struct {
    context: ?*anyopaque = null,
    retain: ?*const fn (?*anyopaque) void = null,
    release: ?*const fn (?*anyopaque) void = null,
};

/// A single `abort` listener owned by native code.
///
/// Registrations never touch the signal object's wrap slot or its `onabort`
/// property: each one installs its own native listener with
/// `addEventListener("abort", ...)` and removes it again on `release()`.
///
/// The registration memory is reference counted, because two independent owners
/// can outlive each other: the native caller (`release`/`releaseWithoutJs`) and
/// the JavaScript listener function (its `napi_wrap` finalizer). Whichever is
/// left last frees it, so a native caller never dereferences a registration a
/// collected listener already released, and a signal-like object that retained
/// the listener can still call it after `release()` - it observes an inactive
/// registration instead of freed memory.
pub const AbortRegistration = struct {
    env: napi.napi_env,
    allocator: std.mem.Allocator,
    /// Strong reference to the listener function; keeps the JS callback alive
    /// while this registration is active.
    listener_ref: napi.napi_ref = null,
    /// Strong reference to the signal object, used to remove the listener.
    signal_ref: napi.napi_ref = null,
    owner: ContextOwner = .{},
    callback: ?AbortCallback = null,
    /// Guards `active` against a listener invocation that is already running.
    mutex: std.Io.Mutex = .init,
    active: bool = false,
    /// Set by the native owner exactly once (guarded by `mutex`).
    native_released: bool = false,
    /// One reference for the native caller, one for the listener function.
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    const Self = @This();

    /// Invoked from the JS `abort` event. Safe to call after `release()`.
    pub fn requestAbort(self: *Self) void {
        const io = registrationIo();
        self.mutex.lockUncancelable(io);
        if (!self.active) {
            self.mutex.unlock(io);
            return;
        }
        const owner = self.owner;
        const callback = self.callback;
        // Take the owner's reference *before* releasing the lock: `deactivate`
        // clears `active` under the same lock, so from here on the owner cannot
        // be destroyed underneath the callback.
        if (owner.context != null) {
            if (owner.retain) |retain_context| retain_context(owner.context);
        }
        self.mutex.unlock(io);

        if (callback) |actual_callback| actual_callback(owner.context);

        if (owner.context != null) {
            if (owner.release) |release_context| release_context(owner.context);
        }
    }

    pub fn isActive(self: *const Self) bool {
        const io = registrationIo();
        const mutable: *Self = @constCast(self);
        mutable.mutex.lockUncancelable(io);
        defer mutable.mutex.unlock(io);
        return self.active;
    }

    /// Current value of the signal object, or null when it is no longer alive.
    pub fn signalValue(self: *const Self) ?napi.napi_value {
        if (self.signal_ref == null) return null;
        var value: napi.napi_value = null;
        if (napi.napi_get_reference_value(self.env, self.signal_ref, &value) != napi.napi_ok) return null;
        return value;
    }

    pub fn isSignalAborted(self: *const Self) bool {
        const signal = self.signalValue() orelse return false;
        return AbortSignal.from_raw(self.env, signal).isAborted() catch false;
    }

    /// Remove the listener and drop every native reference.
    ///
    /// Must run on the environment's JavaScript thread (it calls
    /// `removeEventListener`) and only while that environment is still alive.
    pub fn release(self: *Self) void {
        self.deactivate(true);
    }

    /// Detach without touching JavaScript.
    ///
    /// Used when the environment is already shutting down (for example while a
    /// thread-safe function drains with a null environment) and from native-only
    /// teardown: the listener is marked inactive and the native reference is
    /// dropped, but no `napi_delete_reference` and no JavaScript call happens -
    /// both are invalid once the environment is going away. The remaining
    /// references are reclaimed by the environment.
    pub fn releaseWithoutJs(self: *Self) void {
        self.deactivate(false);
    }

    fn deactivate(self: *Self, allow_js: bool) void {
        const io = registrationIo();
        self.mutex.lockUncancelable(io);
        const was_active = self.active;
        self.active = false;
        const first_release = !self.native_released;
        self.native_released = true;
        self.mutex.unlock(io);

        if (first_release and allow_js and was_active) {
            removeEventListener(self);
        }
        if (first_release and allow_js) {
            if (self.listener_ref != null) {
                _ = napi.napi_delete_reference(self.env, self.listener_ref);
                self.listener_ref = null;
            }
            if (self.signal_ref != null) {
                _ = napi.napi_delete_reference(self.env, self.signal_ref);
                self.signal_ref = null;
            }
        }
        if (first_release) self.dropRef();
    }

    fn dropRef(self: *Self) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

/// Condition-variable-free lock io for the registration handshake. The mutex is
/// only ever held across a few instructions (never across a JavaScript call), so
/// the single threaded io is enough for the futex wake-ups.
fn registrationIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const AbortSignal = struct {
    pub const is_napi_abort_signal = true;

    env: napi.napi_env,
    raw: napi.napi_value,

    const Self = @This();

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
        return .{ .env = env, .raw = raw };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) Self {
        return from_raw(env, raw);
    }

    pub fn isAborted(self: Self) !bool {
        var aborted_value: napi.napi_value = null;
        const get_status = napi.napi_get_named_property(self.env, self.raw, "aborted", &aborted_value);
        if (get_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(get_status));
        }
        if (aborted_value == null) return false;

        var aborted = false;
        const bool_status = napi.napi_get_value_bool(self.env, aborted_value, &aborted);
        if (bool_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(bool_status));
        }
        return aborted;
    }

    /// Register `callback` for the `abort` event.
    ///
    /// The signal must expose `addEventListener`/`removeEventListener` (real
    /// `AbortSignal` objects and the signal-like objects used by tests do).
    /// Foreign wraps, `onabort` handlers and other listeners are left untouched,
    /// and a failure at any step rolls the registration back.
    pub fn bind(self: Self, callback_context: ?*anyopaque, callback: AbortCallback) !*AbortRegistration {
        return self.bindOwned(.{ .context = callback_context }, callback);
    }

    /// Register `callback` with a reference-counted context owner.
    ///
    /// As long as `owner.retain`/`owner.release` are provided, the callback can
    /// never observe a context that its owner already destroyed: see
    /// `ContextOwner`.
    pub fn bindOwned(self: Self, owner: ContextOwner, callback: AbortCallback) !*AbortRegistration {
        const env = self.env;
        if (self.raw == null) {
            return invalidSignal("Expected an AbortSignal-like object, got null");
        }

        var raw_type: napi.napi_valuetype = undefined;
        const typeof_status = napi.napi_typeof(env, self.raw, &raw_type);
        if (typeof_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(typeof_status));
        }
        if (raw_type != napi.napi_object and raw_type != napi.napi_function) {
            return invalidSignal("Expected an AbortSignal-like object");
        }

        const add_listener = try requireSignalMethod(env, self.raw, "addEventListener");
        const remove_listener = try requireSignalMethod(env, self.raw, "removeEventListener");
        _ = remove_listener;

        const allocator = GlobalAllocator.globalAllocator();
        const registration = try allocator.create(AbortRegistration);
        registration.* = .{
            .env = env,
            .allocator = allocator,
        };
        // One reference for the caller, one for the listener function's wrap
        // finalizer. Until `napi_wrap` succeeds only the caller's reference
        // exists, so the rollback below can destroy the allocation directly.
        var listener_owns_reference = false;
        errdefer if (!listener_owns_reference) allocator.destroy(registration);

        var listener: napi.napi_value = null;
        const create_status = napi.napi_create_function(
            env,
            "napiAbortListener",
            "napiAbortListener".len,
            onAbortEvent,
            @ptrCast(registration),
            &listener,
        );
        if (create_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
        }

        const wrap_status = napi.napi_wrap(env, listener, @ptrCast(registration), finalizeRegistration, null, null);
        if (wrap_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(wrap_status));
        }
        listener_owns_reference = true;
        _ = registration.ref_count.fetchAdd(1, .monotonic);

        errdefer if (registration.listener_ref != null) {
            _ = napi.napi_delete_reference(env, registration.listener_ref);
            registration.listener_ref = null;
        };
        errdefer if (registration.signal_ref != null) {
            _ = napi.napi_delete_reference(env, registration.signal_ref);
            registration.signal_ref = null;
        };
        // Runs before the reference cleanup above (errdefers unwind in reverse):
        // the caller's reference is dropped, the listener keeps its own until it
        // is collected.
        errdefer registration.releaseWithoutJs();

        var listener_ref: napi.napi_ref = null;
        const listener_ref_status = napi.napi_create_reference(env, listener, 1, &listener_ref);
        if (listener_ref_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(listener_ref_status));
        }
        registration.listener_ref = listener_ref;

        var signal_ref: napi.napi_ref = null;
        const signal_ref_status = napi.napi_create_reference(env, self.raw, 1, &signal_ref);
        if (signal_ref_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(signal_ref_status));
        }
        registration.signal_ref = signal_ref;

        registration.owner = owner;
        registration.callback = callback;

        const event_name = String.New(Env.from_raw(env), "abort");
        var argv = [2]napi.napi_value{ event_name.raw, listener };
        var ignored: napi.napi_value = null;
        const call_status = napi.napi_call_function(env, self.raw, add_listener, argv.len, &argv, &ignored);
        if (call_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(call_status));
        }

        // Last: a listener that fires while `addEventListener` runs (a hostile
        // signal-like object can do that) must be ignored, not delivered to a
        // context the caller has not received yet.
        const io = registrationIo();
        registration.mutex.lockUncancelable(io);
        registration.native_released = false;
        registration.active = true;
        registration.mutex.unlock(io);
        return registration;
    }
};

fn invalidSignal(message: []const u8) anyerror {
    NapiError.last_error = NapiError.Error.withTypeError(message);
    return error.GenericFailure;
}

fn requireSignalMethod(env: napi.napi_env, signal: napi.napi_value, comptime name: [:0]const u8) !napi.napi_value {
    var member: napi.napi_value = null;
    const status = napi.napi_get_named_property(env, signal, name.ptr, &member);
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
    }
    var member_type: napi.napi_valuetype = undefined;
    const typeof_status = napi.napi_typeof(env, member, &member_type);
    if (typeof_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(typeof_status));
    }
    if (member == null or member_type != napi.napi_function) {
        return invalidSignal("Expected an AbortSignal-like object with a callable " ++ name);
    }
    return member;
}

fn removeEventListener(registration: *AbortRegistration) void {
    const env = registration.env;
    const signal = registration.signalValue() orelse return;
    if (registration.listener_ref == null) return;

    var listener: napi.napi_value = null;
    if (napi.napi_get_reference_value(env, registration.listener_ref, &listener) != napi.napi_ok) return;
    if (listener == null) return;

    const remove_listener = requireSignalMethod(env, signal, "removeEventListener") catch {
        NapiError.clearLastError();
        return;
    };
    const event_name = String.New(Env.from_raw(env), "abort");
    var argv = [2]napi.napi_value{ event_name.raw, listener };
    var ignored: napi.napi_value = null;
    _ = napi.napi_call_function(env, signal, remove_listener, argv.len, &argv, &ignored);
}

fn onAbortEvent(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    var data: ?*anyopaque = null;
    var argc: usize = 0;
    const cb_status = napi.napi_get_cb_info(env, info, &argc, null, null, &data);
    if (cb_status == napi.napi_ok) {
        if (data) |raw| {
            const registration: *AbortRegistration = @ptrCast(@alignCast(raw));
            registration.requestAbort();
        }
    }
    return Undefined.New(Env.from_raw(env)).raw;
}

/// The listener function was collected (or the environment is being torn down).
///
/// Only the listener's own reference is dropped here: the native owner may still
/// hold one, and the memory is freed by whichever reference is released last.
fn finalizeRegistration(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const raw = data orelse return;
    const registration: *AbortRegistration = @ptrCast(@alignCast(raw));
    const io = registrationIo();
    registration.mutex.lockUncancelable(io);
    registration.active = false;
    registration.mutex.unlock(io);
    registration.dropRef();
}

pub fn abortErrorValue(env: Env) !napi.napi_value {
    var code: napi.napi_value = null;
    var message: napi.napi_value = null;
    var error_value: napi.napi_value = null;

    const code_status = napi.napi_create_string_utf8(env.raw, "AbortError", "AbortError".len, &code);
    if (code_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(code_status));
    }
    // Keep the historical message text: existing additions assert on the
    // "AbortError" string in the rejection message.
    const message_status = napi.napi_create_string_utf8(env.raw, "AbortError", "AbortError".len, &message);
    if (message_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(message_status));
    }

    const create_status = napi.napi_create_error(env.raw, code, message, &error_value);
    if (create_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
    }

    const name_status = napi.napi_set_named_property(env.raw, error_value, "name", code);
    if (name_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(name_status));
    }
    return error_value;
}
