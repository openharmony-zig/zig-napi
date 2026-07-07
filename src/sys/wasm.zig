const builtin = @import("builtin");

const node = @import("types.zig");

const is_enabled = builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;

pub const enabled = enabled: {
    _ = AsyncWorkerExports;
    break :enabled is_enabled;
};

pub fn setup() void {
    _ = AsyncWorkerExports;
}

const node_release = "node";

const error_messages = [_][*c]const u8{
    null,
    "Invalid argument",
    "An object was expected",
    "A string was expected",
    "A string or symbol was expected",
    "A function was expected",
    "A number was expected",
    "A boolean was expected",
    "An array was expected",
    "Unknown failure",
    "An exception is pending",
    "The async work item was cancelled",
    "napi_escape_handle already called on scope",
    "Invalid handle scope usage",
    "Invalid callback scope usage",
    "Thread-safe function queue is full",
    "Thread-safe function handle is closing",
    "A bigint was expected",
    "A date was expected",
    "An arraybuffer was expected",
    "A detachable arraybuffer was expected",
    "Main thread would deadlock",
    "External buffers are not allowed",
    "Cannot run JavaScript",
};

const unknown_error_message = "Unknown Node-API error";

var last_error_info = node.napi_extended_error_info{
    .error_message = null,
    .engine_reserved = null,
    .engine_error_code = 0,
    .error_code = node.napi_ok,
};

var node_version = node.napi_node_version{
    .major = 0,
    .minor = 0,
    .patch = 0,
    .release = node_release,
};

var module_filename: ?[*c]u8 = null;

const AsyncContext = extern struct {
    low: i32,
    high: i32,
};

const AsyncCleanupHook = ?*const fn (?*anyopaque, AsyncCleanupDone, ?*anyopaque) callconv(.c) void;
const AsyncCleanupDone = ?*const fn (?*anyopaque) callconv(.c) void;

const AsyncCleanupHookInfo = extern struct {
    env: node.napi_env,
    fun: AsyncCleanupHook,
    arg: ?*anyopaque,
    started: bool,
};

const AsyncCleanupHookHandle = extern struct {
    handle: ?*AsyncCleanupHookInfo,
    env: node.napi_env,
    user_hook: node.napi_async_cleanup_hook,
    user_data: ?*anyopaque,
    done_cb: AsyncCleanupDone,
    done_data: ?*anyopaque,
};

const AsyncWorkerArgs = extern struct {
    stack_base: ?*anyopaque,
    tls_base: ?*anyopaque,
};

const async_worker_stack_size = 2 * 1024 * 1024;

extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

extern fn _emnapi_async_worker(arg: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn _emnapi_spawn_worker(worker: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) callconv(.c) c_int;

fn apiReturnType(comptime Fn: type) type {
    return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
}

pub fn callEmnapiApi(comptime name: [:0]const u8, comptime Fn: type, args: anytype) apiReturnType(Fn) {
    const function = @extern(Fn, .{ .name = name });
    return @call(.auto, function, args);
}

fn asyncWorkerCreate(directly_spawn: c_int, global_address: ?*anyopaque) callconv(.c) c_int {
    // Delegate actual worker creation to @napi-rs/wasm-runtime; this only matches emnapi's C ABI.
    if (directly_spawn != 0) {
        const index = _emnapi_spawn_worker(_emnapi_async_worker, global_address);
        if (index < 0) return 0;
        return -(index + 1);
    }

    const args_size = @sizeOf(AsyncWorkerArgs);
    const total_size = args_size + async_worker_stack_size;
    const block_ptr = calloc(1, total_size) orelse return 0;
    const block_addr = @intFromPtr(block_ptr);
    const args: *AsyncWorkerArgs = @ptrCast(@alignCast(block_ptr));
    args.* = .{
        .stack_base = @ptrFromInt(block_addr + total_size),
        .tls_base = null,
    };
    return @intCast(block_addr);
}

const AsyncWorkerExports = if (is_enabled) struct {
    export fn emnapi_async_worker_create(directly_spawn: c_int, global_address: ?*anyopaque) callconv(.c) c_int {
        return asyncWorkerCreate(directly_spawn, global_address);
    }
} else struct {};

fn setLastError(env: node.node_api_basic_env, status: node.napi_status) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env, node.napi_status, u32, ?*anyopaque) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_set_last_error", Fn, .{ env, status, 0, null });
}

fn clearLastError(env: node.node_api_basic_env) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_clear_last_error", Fn, .{env});
}

fn envCheckGcAccess(env: node.napi_env) void {
    const Fn = *const fn (node.napi_env) callconv(.c) void;
    callEmnapiApi("_emnapi_env_check_gc_access", Fn, .{env});
}

pub fn getLastErrorInfo(env: node.node_api_basic_env, result: [*c][*c]const node.napi_extended_error_info) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    if (result == null) return setLastError(env, node.napi_invalid_arg);

    const Fn = *const fn (node.napi_env, [*c]node.napi_status, [*c]u32, [*c]?*anyopaque) callconv(.c) void;
    callEmnapiApi("_emnapi_get_last_error_info", Fn, .{ env, &last_error_info.error_code, &last_error_info.engine_error_code, &last_error_info.engine_reserved });

    if (last_error_info.error_code < error_messages.len) {
        last_error_info.error_message = error_messages[@intCast(last_error_info.error_code)];
    } else {
        last_error_info.error_message = unknown_error_message;
    }

    if (last_error_info.error_code == node.napi_ok) {
        _ = clearLastError(env);
        last_error_info.engine_error_code = 0;
        last_error_info.engine_reserved = null;
    }

    result.* = &last_error_info;
    return node.napi_ok;
}

pub fn getNodeVersion(env: node.node_api_basic_env, version: [*c][*c]const node.napi_node_version) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    if (version == null) return setLastError(env, node.napi_invalid_arg);

    const Fn = *const fn ([*c]u32, [*c]u32, [*c]u32) callconv(.c) void;
    callEmnapiApi("_emnapi_get_node_version", Fn, .{ &node_version.major, &node_version.minor, &node_version.patch });

    version.* = &node_version;
    return clearLastError(env);
}

pub fn asyncInit(env: node.napi_env, async_resource: node.napi_value, async_resource_name: node.napi_value, result: [*c]node.napi_async_context) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    envCheckGcAccess(env);
    if (async_resource_name == null) return setLastError(env, node.napi_invalid_arg);
    if (result == null) return setLastError(env, node.napi_invalid_arg);

    const context_ptr = malloc(@sizeOf(AsyncContext)) orelse return setLastError(env, node.napi_generic_failure);
    const context: *AsyncContext = @ptrCast(@alignCast(context_ptr));
    const async_context: node.napi_async_context = @ptrCast(context);

    const Fn = *const fn (node.napi_value, node.napi_value, node.napi_async_context) callconv(.c) node.napi_status;
    const status = callEmnapiApi("_emnapi_async_init_js", Fn, .{ async_resource, async_resource_name, async_context });
    if (status != node.napi_ok) {
        free(context_ptr);
        return setLastError(env, status);
    }

    result.* = async_context;
    return clearLastError(env);
}

pub fn asyncDestroy(env: node.napi_env, async_context: node.napi_async_context) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    envCheckGcAccess(env);
    if (async_context == null) return setLastError(env, node.napi_invalid_arg);

    const Fn = *const fn (node.napi_async_context) callconv(.c) node.napi_status;
    const status = callEmnapiApi("_emnapi_async_destroy_js", Fn, .{async_context});
    if (status != node.napi_ok) {
        return setLastError(env, status);
    }

    free(async_context);
    return clearLastError(env);
}

fn runtimeKeepalivePush() void {
    const Fn = *const fn () callconv(.c) void;
    callEmnapiApi("_emnapi_runtime_keepalive_push", Fn, .{});
}

fn runtimeKeepalivePop() void {
    const Fn = *const fn () callconv(.c) void;
    callEmnapiApi("_emnapi_runtime_keepalive_pop", Fn, .{});
}

fn ctxIncreaseWaitingRequestCounter() void {
    const Fn = *const fn () callconv(.c) void;
    callEmnapiApi("_emnapi_ctx_increase_waiting_request_counter", Fn, .{});
}

fn ctxDecreaseWaitingRequestCounter() void {
    const Fn = *const fn () callconv(.c) void;
    callEmnapiApi("_emnapi_ctx_decrease_waiting_request_counter", Fn, .{});
}

fn envRef(env: node.napi_env) void {
    const Fn = *const fn (node.napi_env) callconv(.c) void;
    callEmnapiApi("_emnapi_env_ref", Fn, .{env});
}

fn envUnref(env: node.napi_env) void {
    const Fn = *const fn (node.napi_env) callconv(.c) void;
    callEmnapiApi("_emnapi_env_unref", Fn, .{env});
}

fn setImmediate(callback: AsyncCleanupDone, data: ?*anyopaque) void {
    const Fn = *const fn (AsyncCleanupDone, ?*anyopaque) callconv(.c) void;
    callEmnapiApi("_emnapi_set_immediate", Fn, .{ callback, data });
}

fn finishAsyncCleanupHook(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    runtimeKeepalivePop();
    ctxDecreaseWaitingRequestCounter();
}

fn runAsyncCleanupHook(arg: ?*anyopaque) callconv(.c) void {
    const info: *AsyncCleanupHookInfo = @ptrCast(@alignCast(arg.?));
    runtimeKeepalivePush();
    ctxIncreaseWaitingRequestCounter();
    info.started = true;
    info.fun.?(info.arg, finishAsyncCleanupHook, info);
}

fn achHandleHook(data: ?*anyopaque, done_cb: AsyncCleanupDone, done_data: ?*anyopaque) callconv(.c) void {
    const handle: *AsyncCleanupHookHandle = @ptrCast(@alignCast(data.?));
    handle.done_cb = done_cb;
    handle.done_data = done_data;
    handle.user_hook.?(@ptrCast(handle), handle.user_data);
}

fn addAsyncEnvironmentCleanupHook(env: node.napi_env, fun: AsyncCleanupHook, arg: ?*anyopaque) ?*AsyncCleanupHookInfo {
    const info_ptr = malloc(@sizeOf(AsyncCleanupHookInfo)) orelse return null;
    const info: *AsyncCleanupHookInfo = @ptrCast(@alignCast(info_ptr));
    info.* = .{
        .env = env,
        .fun = fun,
        .arg = arg,
        .started = false,
    };

    const status = node.napi_add_env_cleanup_hook(env, runAsyncCleanupHook, info);
    if (status != node.napi_ok) {
        free(info_ptr);
        return null;
    }

    return info;
}

fn removeAsyncEnvironmentCleanupHook(info: *AsyncCleanupHookInfo) void {
    if (info.started) return;
    _ = node.napi_remove_env_cleanup_hook(info.env, runAsyncCleanupHook, info);
}

fn achHandleCreate(env: node.napi_env, user_hook: node.napi_async_cleanup_hook, user_data: ?*anyopaque) ?*AsyncCleanupHookHandle {
    const handle_ptr = calloc(1, @sizeOf(AsyncCleanupHookHandle)) orelse return null;
    const handle: *AsyncCleanupHookHandle = @ptrCast(@alignCast(handle_ptr));
    handle.env = env;
    handle.user_hook = user_hook;
    handle.user_data = user_data;
    handle.handle = addAsyncEnvironmentCleanupHook(env, achHandleHook, handle) orelse {
        free(handle_ptr);
        return null;
    };
    envRef(env);

    return handle;
}

fn achHandleEnvUnref(arg: ?*anyopaque) callconv(.c) void {
    envUnref(@ptrCast(arg));
}

fn achHandleDelete(handle: *AsyncCleanupHookHandle) void {
    if (handle.handle) |info| {
        removeAsyncEnvironmentCleanupHook(info);
        free(info);
    }
    if (handle.done_cb) |done_cb| done_cb(handle.done_data);

    setImmediate(achHandleEnvUnref, handle.env);
    free(handle);
}

pub fn addAsyncCleanupHook(env: node.node_api_basic_env, hook: node.napi_async_cleanup_hook, data: ?*anyopaque, remove_handle: [*c]node.napi_async_cleanup_hook_handle) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    if (hook == null) return setLastError(env, node.napi_invalid_arg);

    const handle = achHandleCreate(env, hook, data) orelse return setLastError(env, node.napi_generic_failure);
    if (remove_handle != null) {
        remove_handle.* = @ptrCast(handle);
    }

    return clearLastError(env);
}

pub fn removeAsyncCleanupHook(remove_handle: node.napi_async_cleanup_hook_handle) node.napi_status {
    const handle = remove_handle orelse return node.napi_invalid_arg;
    achHandleDelete(@ptrCast(@alignCast(handle)));
    return node.napi_ok;
}

pub fn getModuleFileName(env: node.node_api_basic_env, result: [*c][*c]const u8) node.napi_status {
    if (env == null) return node.napi_invalid_arg;
    if (result == null) return setLastError(env, node.napi_invalid_arg);

    if (module_filename) |filename| {
        free(filename);
        module_filename = null;
    }

    const Fn = *const fn (node.napi_env, [*c]u8, c_int) callconv(.c) c_int;
    var len = callEmnapiApi("_emnapi_get_filename", Fn, .{ env, null, 0 });
    if (len == 0) {
        result.* = "";
    } else {
        const filename_ptr = malloc(@intCast(len + 1)) orelse return setLastError(env, node.napi_generic_failure);
        const filename: [*c]u8 = @ptrCast(@alignCast(filename_ptr));
        len = callEmnapiApi("_emnapi_get_filename", Fn, .{ env, filename, len + 1 });
        filename[@intCast(len)] = 0;
        module_filename = filename;
        result.* = filename;
    }

    return clearLastError(env);
}

pub fn syncMemory(env: node.napi_env, js_to_wasm: bool, array: [*c]node.napi_value, byte_offset: usize, byte_length: usize) node.napi_status {
    if (enabled) {
        const Fn = *const fn (node.napi_env, bool, [*c]node.napi_value, usize, usize) callconv(.c) node.napi_status;
        return callEmnapiApi("emnapi_sync_memory", Fn, .{ env, js_to_wasm, array, byte_offset, byte_length });
    }
    return node.napi_ok;
}
