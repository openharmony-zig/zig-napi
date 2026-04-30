const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("./env.zig").Env;
const String = @import("./value/string.zig").String;
const Undefined = @import("./value/undefined.zig").Undefined;
const NapiError = @import("./wrapper/error.zig");
const GlobalAllocator = @import("./util/allocator.zig");

pub const AbortCallback = *const fn (?*anyopaque) void;

const AbortRegistrationStack = struct {
    allocator: std.mem.Allocator,
    registrations: std.array_list.Managed(*AbortRegistration),

    fn init(allocator: std.mem.Allocator) AbortRegistrationStack {
        return .{
            .allocator = allocator,
            .registrations = std.array_list.Managed(*AbortRegistration).init(allocator),
        };
    }

    fn deinit(self: *AbortRegistrationStack) void {
        self.registrations.deinit();
    }

    fn append(self: *AbortRegistrationStack, registration: *AbortRegistration) !void {
        try self.registrations.append(registration);
    }

    fn remove(self: *AbortRegistrationStack, registration: *AbortRegistration) void {
        for (self.registrations.items, 0..) |item, index| {
            if (item == registration) {
                _ = self.registrations.swapRemove(index);
                return;
            }
        }
    }
};

pub const AbortRegistration = struct {
    env: napi.napi_env,
    signal_ref: napi.napi_ref,
    stack: *AbortRegistrationStack,
    callback_context: ?*anyopaque,
    callback: AbortCallback,
    active: bool = true,

    pub fn requestAbort(self: *AbortRegistration) void {
        if (!self.active) return;
        self.callback(self.callback_context);
    }

    pub fn release(self: *AbortRegistration) void {
        if (self.active) {
            self.stack.remove(self);
            self.active = false;
        }
        if (self.signal_ref != null) {
            _ = napi.napi_delete_reference(self.env, self.signal_ref);
            self.signal_ref = null;
        }
        GlobalAllocator.globalAllocator().destroy(self);
    }
};

pub const AbortSignal = struct {
    pub const is_napi_abort_signal = true;

    env: napi.napi_env,
    raw: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) AbortSignal {
        return .{ .env = env, .raw = raw };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) AbortSignal {
        return from_raw(env, raw);
    }

    pub fn isAborted(self: AbortSignal) !bool {
        var aborted_value: napi.napi_value = undefined;
        const get_status = napi.napi_get_named_property(self.env, self.raw, "aborted", &aborted_value);
        if (get_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(get_status));
        }

        var aborted = false;
        const bool_status = napi.napi_get_value_bool(self.env, aborted_value, &aborted);
        if (bool_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(bool_status));
        }
        return aborted;
    }

    pub fn bind(self: AbortSignal, callback_context: ?*anyopaque, callback: AbortCallback) !*AbortRegistration {
        const stack = try ensureStack(self.env, self.raw);

        const allocator = GlobalAllocator.globalAllocator();
        const registration = try allocator.create(AbortRegistration);
        errdefer allocator.destroy(registration);

        var signal_ref: napi.napi_ref = null;
        const ref_status = napi.napi_create_reference(self.env, self.raw, 1, &signal_ref);
        if (ref_status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(ref_status));
        }
        errdefer _ = napi.napi_delete_reference(self.env, signal_ref);

        registration.* = .{
            .env = self.env,
            .signal_ref = signal_ref,
            .stack = stack,
            .callback_context = callback_context,
            .callback = callback,
        };
        try stack.append(registration);
        return registration;
    }
};

fn ensureStack(env: napi.napi_env, signal: napi.napi_value) !*AbortRegistrationStack {
    const allocator = GlobalAllocator.globalAllocator();

    var stack_ptr: ?*anyopaque = null;
    const remove_status = napi.napi_remove_wrap(env, signal, &stack_ptr);
    const stack: *AbortRegistrationStack = if (remove_status == napi.napi_ok and stack_ptr != null)
        @ptrCast(@alignCast(stack_ptr.?))
    else blk: {
        const new_stack = try allocator.create(AbortRegistrationStack);
        new_stack.* = AbortRegistrationStack.init(allocator);
        break :blk new_stack;
    };

    errdefer if (!(remove_status == napi.napi_ok and stack_ptr != null)) {
        stack.deinit();
        allocator.destroy(stack);
    };

    var ref: napi.napi_ref = null;
    const wrap_status = napi.napi_wrap(env, signal, @ptrCast(stack), finalizeStack, null, &ref);
    if (wrap_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(wrap_status));
    }
    if (ref != null) {
        var ref_count: u32 = 0;
        _ = napi.napi_reference_unref(env, ref, &ref_count);
    }

    try installOnAbort(env, signal);
    return stack;
}

fn installOnAbort(env: napi.napi_env, signal: napi.napi_value) !void {
    var callback: napi.napi_value = undefined;
    const create_status = napi.napi_create_function(
        env,
        "onabort",
        "onabort".len,
        onAbort,
        null,
        &callback,
    );
    if (create_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
    }

    const set_status = napi.napi_set_named_property(env, signal, "onabort", callback);
    if (set_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(set_status));
    }
}

fn onAbort(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    var this: napi.napi_value = null;
    var argc: usize = 0;
    const cb_status = napi.napi_get_cb_info(env, info, &argc, null, &this, null);
    if (cb_status == napi.napi_ok and this != null) {
        var stack_ptr: ?*anyopaque = null;
        const unwrap_status = napi.napi_unwrap(env, this, &stack_ptr);
        if (unwrap_status == napi.napi_ok and stack_ptr != null) {
            const stack: *AbortRegistrationStack = @ptrCast(@alignCast(stack_ptr.?));
            for (stack.registrations.items) |registration| {
                registration.requestAbort();
            }
        }
    }

    return Undefined.New(Env.from_raw(env)).raw;
}

fn finalizeStack(_: napi.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const data = finalize_data orelse return;
    const stack: *AbortRegistrationStack = @ptrCast(@alignCast(data));
    stack.deinit();
    GlobalAllocator.globalAllocator().destroy(stack);
}

pub fn abortErrorValue(env: Env) napi.napi_value {
    var error_value: napi.napi_value = undefined;
    const code = String.New(env, "AbortError").raw;
    const message = String.New(env, "AbortError").raw;
    const create_status = napi.napi_create_error(env.raw, code, message, &error_value);
    std.debug.assert(create_status == napi.napi_ok);
    const set_status = napi.napi_set_named_property(env.raw, error_value, "name", code);
    std.debug.assert(set_status == napi.napi_ok);
    return error_value;
}
