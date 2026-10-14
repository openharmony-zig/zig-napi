const std = @import("std");
const napi = @import("napi-sys").napi_sys;

pub const Dispatcher = struct {
    context: ?*anyopaque,
    finalize: napi.napi_finalize,
    dispose: napi.napi_threadsafe_function_call_js,
    status: napi.napi_status = napi.napi_ok,
    queued: bool = false,
    calls: usize = 0,
    releases: usize = 0,

    pub fn raw(self: *@This()) napi.napi_threadsafe_function {
        return @ptrCast(self);
    }
    pub fn finish(self: *@This()) void {
        self.finalize.?(env, self.context, null);
        if (self.queued) self.dispose.?(null, null, self.context, null);
    }
};

pub const env: napi.napi_env = @ptrFromInt(1);
pub var deleted_references: usize = 0;
pub var removed_hooks: usize = 0;

export fn napi_call_threadsafe_function(raw: napi.napi_threadsafe_function, _: ?*anyopaque, mode: napi.napi_threadsafe_function_call_mode) callconv(.c) napi.napi_status {
    std.debug.assert(mode == napi.napi_tsfn_nonblocking);
    const dispatcher: *Dispatcher = @ptrCast(@alignCast(raw.?));
    dispatcher.calls += 1;
    dispatcher.queued = dispatcher.status == napi.napi_ok;
    return dispatcher.status;
}

export fn napi_release_threadsafe_function(raw: napi.napi_threadsafe_function, _: napi.napi_threadsafe_function_release_mode) callconv(.c) napi.napi_status {
    const dispatcher: *Dispatcher = @ptrCast(@alignCast(raw.?));
    dispatcher.releases += 1;
    return napi.napi_ok;
}

export fn napi_remove_env_cleanup_hook(inner_env: napi.node_api_basic_env, _: napi.napi_cleanup_hook, _: ?*anyopaque) callconv(.c) napi.napi_status {
    std.debug.assert(inner_env != null);
    removed_hooks += 1;
    return napi.napi_ok;
}

export fn napi_delete_reference(inner_env: napi.node_api_basic_env, _: napi.napi_ref) callconv(.c) napi.napi_status {
    std.debug.assert(inner_env != null);
    if (runtime.delete_status != napi.napi_ok) return runtime.delete_status;
    deleted_references += 1;
    return napi.napi_ok;
}

pub const Runtime = struct {
    type_status: napi.napi_status = napi.napi_ok,
    external_status: napi.napi_status = napi.napi_ok,
    external_data: ?*anyopaque = @ptrFromInt(1),
    input_type: napi.napi_valuetype = napi.napi_number,
    output_type: napi.napi_valuetype = napi.napi_undefined,
    number: f64 = 0,
    unsigned: u64 = 0,
    signed: i64 = 0,
    lossless: bool = true,
    cb_status: napi.napi_status = napi.napi_ok,
    argc: usize = 0,
    undefined_status: napi.napi_status = napi.napi_ok,
    string_failure: usize = 0,
    string_calls: usize = 0,
    create_status: napi.napi_status = napi.napi_ok,
    throw_status: napi.napi_status = napi.napi_ok,
    pending: bool = false,
    creates: usize = 0,
    throws: usize = 0,
    fallbacks: usize = 0,
    code: napi.napi_value = null,
    count: u32 = 0,
    unrefs: usize = 0,
    delete_status: napi.napi_status = napi.napi_ok,
};
pub var runtime: Runtime = .{};
pub const value_raw: napi.napi_value = @ptrFromInt(2);
pub const undefined_raw: napi.napi_value = @ptrFromInt(3);
var bytes = [_]u8{ 1, 2, 3 };

export fn napi_get_cb_info(_: napi.napi_env, _: napi.napi_callback_info, argc: ?*usize, _: [*c]napi.napi_value, receiver: [*c]napi.napi_value, data: [*c]?*anyopaque) callconv(.c) napi.napi_status {
    if (runtime.cb_status != napi.napi_ok) return runtime.cb_status;
    if (argc) |count| count.* = runtime.argc;
    if (receiver != null) receiver.* = value_raw;
    if (data != null) data.* = null;
    return napi.napi_ok;
}
export fn napi_get_undefined(_: napi.napi_env, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    if (runtime.undefined_status == napi.napi_ok) value.* = undefined_raw;
    return runtime.undefined_status;
}
export fn napi_is_exception_pending(_: napi.napi_env, pending: [*c]bool) callconv(.c) napi.napi_status {
    pending.* = runtime.pending;
    return napi.napi_ok;
}
export fn napi_create_string_utf8(_: napi.napi_env, _: [*c]const u8, _: usize, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    runtime.string_calls += 1;
    if (runtime.string_calls == runtime.string_failure) return napi.napi_generic_failure;
    value.* = value_raw;
    return napi.napi_ok;
}
export fn napi_create_error(_: napi.napi_env, code: napi.napi_value, _: napi.napi_value, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    runtime.creates += 1;
    runtime.code = code;
    if (runtime.create_status == napi.napi_ok) value.* = value_raw;
    return runtime.create_status;
}
export fn napi_create_type_error(env_: napi.napi_env, code: napi.napi_value, message: napi.napi_value, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    return napi_create_error(env_, code, message, value);
}
export fn napi_create_range_error(env_: napi.napi_env, code: napi.napi_value, message: napi.napi_value, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    return napi_create_error(env_, code, message, value);
}
export fn napi_throw(_: napi.napi_env, value: napi.napi_value) callconv(.c) napi.napi_status {
    std.debug.assert(value == value_raw);
    runtime.throws += 1;
    if (runtime.throw_status == napi.napi_ok) runtime.pending = true;
    return runtime.throw_status;
}
export fn napi_throw_error(_: napi.napi_env, _: [*c]const u8, _: [*c]const u8) callconv(.c) napi.napi_status {
    runtime.fallbacks += 1;
    runtime.pending = true;
    return napi.napi_ok;
}
export fn napi_get_buffer_info(_: napi.napi_env, _: napi.napi_value, data: [*c]?*anyopaque, len: [*c]usize) callconv(.c) napi.napi_status {
    data.* = &bytes;
    len.* = bytes.len;
    return napi.napi_ok;
}
export fn napi_get_arraybuffer_info(env_: napi.napi_env, value: napi.napi_value, data: [*c]?*anyopaque, len: [*c]usize) callconv(.c) napi.napi_status {
    return napi_get_buffer_info(env_, value, data, len);
}
export fn napi_create_function(_: napi.napi_env, _: [*c]const u8, _: usize, _: napi.napi_callback, _: ?*anyopaque, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    value.* = value_raw;
    return napi.napi_ok;
}
export fn napi_reference_unref(_: napi.napi_env, _: napi.napi_ref, count: [*c]u32) callconv(.c) napi.napi_status {
    runtime.unrefs += 1;
    if (runtime.count == 0) return napi.napi_generic_failure;
    runtime.count -= 1;
    count.* = runtime.count;
    return napi.napi_ok;
}
export fn napi_reference_ref(_: napi.napi_env, _: napi.napi_ref, count: [*c]u32) callconv(.c) napi.napi_status {
    runtime.count += 1;
    count.* = runtime.count;
    return napi.napi_ok;
}
export fn napi_get_reference_value(_: napi.napi_env, _: napi.napi_ref, value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    value.* = value_raw;
    return napi.napi_ok;
}

export fn napi_typeof(_: napi.napi_env, _: napi.napi_value, value_type: [*c]napi.napi_valuetype) callconv(.c) napi.napi_status {
    if (runtime.type_status != napi.napi_ok) return runtime.type_status;
    value_type.* = runtime.input_type;
    return napi.napi_ok;
}
export fn napi_get_value_double(_: napi.napi_env, _: napi.napi_value, value: [*c]f64) callconv(.c) napi.napi_status {
    value.* = runtime.number;
    return napi.napi_ok;
}
export fn napi_create_double(_: napi.napi_env, value: f64, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    runtime.number = value;
    runtime.output_type = napi.napi_number;
    raw_value.* = value_raw;
    return napi.napi_ok;
}
export fn napi_create_int32(env_: napi.napi_env, value: i32, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    return napi_create_double(env_, @floatFromInt(value), raw_value);
}
export fn napi_create_uint32(env_: napi.napi_env, value: u32, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    return napi_create_double(env_, @floatFromInt(value), raw_value);
}
export fn napi_create_int64(env_: napi.napi_env, value: i64, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    return napi_create_double(env_, @floatFromInt(value), raw_value);
}
export fn napi_create_bigint_uint64(_: napi.napi_env, value: u64, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    runtime.output_type = napi.napi_bigint;
    runtime.unsigned = value;
    raw_value.* = value_raw;
    return napi.napi_ok;
}
export fn napi_create_bigint_int64(_: napi.napi_env, value: i64, raw_value: [*c]napi.napi_value) callconv(.c) napi.napi_status {
    runtime.output_type = napi.napi_bigint;
    runtime.signed = value;
    raw_value.* = value_raw;
    return napi.napi_ok;
}
export fn napi_get_value_bigint_uint64(_: napi.napi_env, _: napi.napi_value, value: [*c]u64, lossless: [*c]bool) callconv(.c) napi.napi_status {
    value.* = runtime.unsigned;
    lossless.* = runtime.lossless;
    return napi.napi_ok;
}
export fn napi_get_value_bigint_int64(_: napi.napi_env, _: napi.napi_value, value: [*c]i64, lossless: [*c]bool) callconv(.c) napi.napi_status {
    value.* = runtime.signed;
    lossless.* = runtime.lossless;
    return napi.napi_ok;
}

export fn napi_get_value_external(_: napi.napi_env, _: napi.napi_value, value: [*c]?*anyopaque) callconv(.c) napi.napi_status {
    if (runtime.external_status != napi.napi_ok) return runtime.external_status;
    value.* = runtime.external_data;
    return napi.napi_ok;
}
