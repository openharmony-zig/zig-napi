const std = @import("std");
const builtin = @import("builtin");

pub const napi_env__ = opaque {};
pub const napi_value__ = opaque {};
pub const napi_ref__ = opaque {};
pub const napi_handle_scope__ = opaque {};
pub const napi_escapable_handle_scope__ = opaque {};
pub const napi_callback_info__ = opaque {};
pub const napi_deferred__ = opaque {};
pub const napi_callback_scope__ = opaque {};
pub const napi_async_context__ = opaque {};
pub const napi_async_work__ = opaque {};

pub const napi_env = ?*napi_env__;
pub const node_api_basic_env = napi_env;
pub const napi_value = ?*napi_value__;
pub const napi_ref = ?*napi_ref__;
pub const napi_handle_scope = ?*napi_handle_scope__;
pub const napi_escapable_handle_scope = ?*napi_escapable_handle_scope__;
pub const napi_callback_info = ?*napi_callback_info__;
pub const napi_deferred = ?*napi_deferred__;
pub const napi_callback_scope = ?*napi_callback_scope__;
pub const napi_async_context = ?*napi_async_context__;
pub const napi_async_work = ?*napi_async_work__;

pub const napi_property_attributes = c_int;
pub const napi_default: napi_property_attributes = 0;
pub const napi_writable: napi_property_attributes = 1 << 0;
pub const napi_enumerable: napi_property_attributes = 1 << 1;
pub const napi_configurable: napi_property_attributes = 1 << 2;
pub const napi_static: napi_property_attributes = 1 << 10;
pub const napi_default_method: napi_property_attributes = napi_writable | napi_configurable;
pub const napi_default_jsproperty: napi_property_attributes = napi_writable | napi_enumerable | napi_configurable;

pub const napi_valuetype = c_int;
pub const napi_undefined: napi_valuetype = 0;
pub const napi_null: napi_valuetype = 1;
pub const napi_boolean: napi_valuetype = 2;
pub const napi_number: napi_valuetype = 3;
pub const napi_string: napi_valuetype = 4;
pub const napi_symbol: napi_valuetype = 5;
pub const napi_object: napi_valuetype = 6;
pub const napi_function: napi_valuetype = 7;
pub const napi_external: napi_valuetype = 8;

pub const napi_typedarray_type = c_int;
pub const napi_int8_array: napi_typedarray_type = 0;
pub const napi_uint8_array: napi_typedarray_type = 1;
pub const napi_uint8_clamped_array: napi_typedarray_type = 2;
pub const napi_int16_array: napi_typedarray_type = 3;
pub const napi_uint16_array: napi_typedarray_type = 4;
pub const napi_int32_array: napi_typedarray_type = 5;
pub const napi_uint32_array: napi_typedarray_type = 6;
pub const napi_float32_array: napi_typedarray_type = 7;
pub const napi_float64_array: napi_typedarray_type = 8;

pub const napi_status = c_int;
pub const napi_ok: napi_status = 0;
pub const napi_invalid_arg: napi_status = 1;
pub const napi_object_expected: napi_status = 2;
pub const napi_string_expected: napi_status = 3;
pub const napi_name_expected: napi_status = 4;
pub const napi_function_expected: napi_status = 5;
pub const napi_number_expected: napi_status = 6;
pub const napi_boolean_expected: napi_status = 7;
pub const napi_array_expected: napi_status = 8;
pub const napi_generic_failure: napi_status = 9;
pub const napi_pending_exception: napi_status = 10;
pub const napi_cancelled: napi_status = 11;
pub const napi_escape_called_twice: napi_status = 12;
pub const napi_handle_scope_mismatch: napi_status = 13;
pub const napi_callback_scope_mismatch: napi_status = 14;
pub const napi_queue_full: napi_status = 15;
pub const napi_closing: napi_status = 16;
pub const napi_bigint_expected: napi_status = 17;
pub const napi_date_expected: napi_status = 18;
pub const napi_arraybuffer_expected: napi_status = 19;
pub const napi_detachable_arraybuffer_expected: napi_status = 20;
pub const napi_would_deadlock: napi_status = 21;
pub const napi_no_external_buffers_allowed: napi_status = 22;
pub const napi_cannot_run_js: napi_status = 23;

pub const napi_callback = ?*const fn (env: napi_env, info: napi_callback_info) callconv(.c) napi_value;
pub const napi_finalize = ?*const fn (env: napi_env, finalize_data: ?*anyopaque, finalize_hint: ?*anyopaque) callconv(.c) void;
pub const node_api_basic_finalize = napi_finalize;
pub const napi_cleanup_hook = ?*const fn (arg: ?*anyopaque) callconv(.c) void;
pub const napi_async_execute_callback = ?*const fn (env: napi_env, data: ?*anyopaque) callconv(.c) void;
pub const napi_async_complete_callback = ?*const fn (env: napi_env, status: napi_status, data: ?*anyopaque) callconv(.c) void;
pub const napi_addon_register_func = ?*const fn (env: napi_env, exports: napi_value) callconv(.c) napi_value;

pub const napi_property_descriptor = extern struct {
    utf8name: [*c]const u8,
    name: napi_value,
    method: napi_callback,
    getter: napi_callback,
    setter: napi_callback,
    value: napi_value,
    attributes: napi_property_attributes,
    data: ?*anyopaque,
};

pub const napi_extended_error_info = extern struct {
    error_message: [*c]const u8,
    engine_reserved: ?*anyopaque,
    engine_error_code: u32,
    error_code: napi_status,
};

pub const napi_node_version = extern struct {
    major: u32,
    minor: u32,
    patch: u32,
    release: [*c]const u8,
};

pub const napi_module = extern struct {
    nm_version: c_int,
    nm_flags: c_uint,
    nm_filename: [*c]const u8,
    nm_register_func: napi_addon_register_func,
    nm_modname: [*c]const u8,
    nm_priv: ?*anyopaque,
    reserved: [4]?*anyopaque,
};

const use_windows_msvc_dynamic_symbols = builtin.os.tag == .windows and builtin.abi == .msvc;

const WindowsMsvcLoader = struct {
    const windows = std.os.windows;

    extern "kernel32" fn GetModuleHandleExW(dwFlags: u32, lpModuleName: ?windows.LPCWSTR, phModule: *windows.HMODULE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: windows.LPCSTR) callconv(.winapi) ?windows.FARPROC;

    var initialized = false;
    var host: ?windows.HMODULE = null;

    fn setup() void {
        if (initialized) return;
        var handle: windows.HMODULE = undefined;
        if (GetModuleHandleExW(0, null, &handle).toBool()) {
            host = handle;
        }
        initialized = true;
    }

    fn lookup(comptime Fn: type, comptime name: [:0]const u8) ?Fn {
        @This().setup();
        const module = host orelse return null;
        const proc = GetProcAddress(module, name.ptr) orelse return null;
        return @as(Fn, @ptrCast(@alignCast(proc)));
    }

    fn lookupCached(comptime Fn: type, comptime name: [:0]const u8) ?Fn {
        const Cache = struct {
            var initialized = false;
            var symbol: ?Fn = null;
        };
        if (!Cache.initialized) {
            Cache.symbol = lookup(Fn, name);
            Cache.initialized = true;
        }
        return Cache.symbol;
    }
};

pub fn setup() void {
    if (use_windows_msvc_dynamic_symbols) {
        WindowsMsvcLoader.setup();
        loadAllNodeApiSymbols();
    }
}

fn nodeApiReturnType(comptime Fn: type) type {
    return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
}

fn missingNodeApiSymbol(comptime name: [:0]const u8, comptime Return: type) Return {
    std.debug.print("Node-API symbol {s} has not been loaded\n", .{name});
    if (Return == napi_status) return napi_invalid_arg;
    if (Return == void) return;
    if (Return == noreturn) @panic("Node-API symbol has not been loaded");
    return std.mem.zeroes(Return);
}

fn callNodeApi(comptime name: [:0]const u8, comptime Fn: type, args: anytype) nodeApiReturnType(Fn) {
    if (use_windows_msvc_dynamic_symbols) {
        const function = WindowsMsvcLoader.lookupCached(Fn, name) orelse return missingNodeApiSymbol(name, nodeApiReturnType(Fn));
        return @call(.auto, function, args);
    }

    const function = @extern(Fn, .{ .name = name });
    return @call(.auto, function, args);
}

fn loadNodeApi(comptime name: [:0]const u8, comptime wrapper: anytype) void {
    const Fn = *const @TypeOf(wrapper);
    _ = WindowsMsvcLoader.lookupCached(Fn, name);
}

fn loadAllNodeApiSymbols() void {
    if (!use_windows_msvc_dynamic_symbols) return;

    loadNodeApi("napi_get_last_error_info", napi_get_last_error_info);
    loadNodeApi("napi_get_undefined", napi_get_undefined);
    loadNodeApi("napi_get_null", napi_get_null);
    loadNodeApi("napi_get_global", napi_get_global);
    loadNodeApi("napi_get_boolean", napi_get_boolean);
    loadNodeApi("napi_create_object", napi_create_object);
    loadNodeApi("napi_create_array", napi_create_array);
    loadNodeApi("napi_create_array_with_length", napi_create_array_with_length);
    loadNodeApi("napi_create_double", napi_create_double);
    loadNodeApi("napi_create_int32", napi_create_int32);
    loadNodeApi("napi_create_uint32", napi_create_uint32);
    loadNodeApi("napi_create_int64", napi_create_int64);
    loadNodeApi("napi_create_string_latin1", napi_create_string_latin1);
    loadNodeApi("napi_create_string_utf8", napi_create_string_utf8);
    loadNodeApi("napi_create_string_utf16", napi_create_string_utf16);
    loadNodeApi("napi_create_symbol", napi_create_symbol);
    loadNodeApi("napi_create_function", napi_create_function);
    loadNodeApi("napi_create_error", napi_create_error);
    loadNodeApi("napi_create_type_error", napi_create_type_error);
    loadNodeApi("napi_create_range_error", napi_create_range_error);
    loadNodeApi("napi_typeof", napi_typeof);
    loadNodeApi("napi_get_value_double", napi_get_value_double);
    loadNodeApi("napi_get_value_int32", napi_get_value_int32);
    loadNodeApi("napi_get_value_uint32", napi_get_value_uint32);
    loadNodeApi("napi_get_value_int64", napi_get_value_int64);
    loadNodeApi("napi_get_value_bool", napi_get_value_bool);
    loadNodeApi("napi_get_value_string_latin1", napi_get_value_string_latin1);
    loadNodeApi("napi_get_value_string_utf8", napi_get_value_string_utf8);
    loadNodeApi("napi_get_value_string_utf16", napi_get_value_string_utf16);
    loadNodeApi("napi_coerce_to_bool", napi_coerce_to_bool);
    loadNodeApi("napi_coerce_to_number", napi_coerce_to_number);
    loadNodeApi("napi_coerce_to_object", napi_coerce_to_object);
    loadNodeApi("napi_coerce_to_string", napi_coerce_to_string);
    loadNodeApi("napi_get_prototype", napi_get_prototype);
    loadNodeApi("napi_get_property_names", napi_get_property_names);
    loadNodeApi("napi_set_property", napi_set_property);
    loadNodeApi("napi_has_property", napi_has_property);
    loadNodeApi("napi_get_property", napi_get_property);
    loadNodeApi("napi_delete_property", napi_delete_property);
    loadNodeApi("napi_has_own_property", napi_has_own_property);
    loadNodeApi("napi_set_named_property", napi_set_named_property);
    loadNodeApi("napi_has_named_property", napi_has_named_property);
    loadNodeApi("napi_get_named_property", napi_get_named_property);
    loadNodeApi("napi_set_element", napi_set_element);
    loadNodeApi("napi_has_element", napi_has_element);
    loadNodeApi("napi_get_element", napi_get_element);
    loadNodeApi("napi_delete_element", napi_delete_element);
    loadNodeApi("napi_define_properties", napi_define_properties);
    loadNodeApi("napi_is_array", napi_is_array);
    loadNodeApi("napi_get_array_length", napi_get_array_length);
    loadNodeApi("napi_strict_equals", napi_strict_equals);
    loadNodeApi("napi_call_function", napi_call_function);
    loadNodeApi("napi_new_instance", napi_new_instance);
    loadNodeApi("napi_instanceof", napi_instanceof);
    loadNodeApi("napi_get_cb_info", napi_get_cb_info);
    loadNodeApi("napi_get_new_target", napi_get_new_target);
    loadNodeApi("napi_define_class", napi_define_class);
    loadNodeApi("napi_wrap", napi_wrap);
    loadNodeApi("napi_unwrap", napi_unwrap);
    loadNodeApi("napi_remove_wrap", napi_remove_wrap);
    loadNodeApi("napi_create_external", napi_create_external);
    loadNodeApi("napi_get_value_external", napi_get_value_external);
    loadNodeApi("napi_create_reference", napi_create_reference);
    loadNodeApi("napi_delete_reference", napi_delete_reference);
    loadNodeApi("napi_reference_ref", napi_reference_ref);
    loadNodeApi("napi_reference_unref", napi_reference_unref);
    loadNodeApi("napi_get_reference_value", napi_get_reference_value);
    loadNodeApi("napi_open_handle_scope", napi_open_handle_scope);
    loadNodeApi("napi_close_handle_scope", napi_close_handle_scope);
    loadNodeApi("napi_open_escapable_handle_scope", napi_open_escapable_handle_scope);
    loadNodeApi("napi_close_escapable_handle_scope", napi_close_escapable_handle_scope);
    loadNodeApi("napi_escape_handle", napi_escape_handle);
    loadNodeApi("napi_throw", napi_throw);
    loadNodeApi("napi_throw_error", napi_throw_error);
    loadNodeApi("napi_throw_type_error", napi_throw_type_error);
    loadNodeApi("napi_throw_range_error", napi_throw_range_error);
    loadNodeApi("napi_is_error", napi_is_error);
    loadNodeApi("napi_is_exception_pending", napi_is_exception_pending);
    loadNodeApi("napi_get_and_clear_last_exception", napi_get_and_clear_last_exception);
    loadNodeApi("napi_is_arraybuffer", napi_is_arraybuffer);
    loadNodeApi("napi_create_arraybuffer", napi_create_arraybuffer);
    loadNodeApi("napi_create_external_arraybuffer", napi_create_external_arraybuffer);
    loadNodeApi("napi_get_arraybuffer_info", napi_get_arraybuffer_info);
    loadNodeApi("napi_is_typedarray", napi_is_typedarray);
    loadNodeApi("napi_create_typedarray", napi_create_typedarray);
    loadNodeApi("napi_get_typedarray_info", napi_get_typedarray_info);
    loadNodeApi("napi_create_dataview", napi_create_dataview);
    loadNodeApi("napi_is_dataview", napi_is_dataview);
    loadNodeApi("napi_get_dataview_info", napi_get_dataview_info);
    loadNodeApi("napi_get_version", napi_get_version);
    loadNodeApi("napi_create_promise", napi_create_promise);
    loadNodeApi("napi_resolve_deferred", napi_resolve_deferred);
    loadNodeApi("napi_reject_deferred", napi_reject_deferred);
    loadNodeApi("napi_is_promise", napi_is_promise);
    loadNodeApi("napi_run_script", napi_run_script);
    loadNodeApi("napi_adjust_external_memory", napi_adjust_external_memory);
    loadNodeApi("napi_module_register", napi_module_register);
    loadNodeApi("napi_fatal_error", napi_fatal_error);
    loadNodeApi("napi_async_init", napi_async_init);
    loadNodeApi("napi_async_destroy", napi_async_destroy);
    loadNodeApi("napi_make_callback", napi_make_callback);
    loadNodeApi("napi_create_buffer", napi_create_buffer);
    loadNodeApi("napi_create_external_buffer", napi_create_external_buffer);
    loadNodeApi("napi_create_buffer_copy", napi_create_buffer_copy);
    loadNodeApi("napi_is_buffer", napi_is_buffer);
    loadNodeApi("napi_get_buffer_info", napi_get_buffer_info);
    loadNodeApi("napi_create_async_work", napi_create_async_work);
    loadNodeApi("napi_delete_async_work", napi_delete_async_work);
    loadNodeApi("napi_queue_async_work", napi_queue_async_work);
    loadNodeApi("napi_cancel_async_work", napi_cancel_async_work);
    loadNodeApi("napi_get_node_version", napi_get_node_version);
    loadNodeApi("napi_fatal_exception", napi_fatal_exception);
    loadNodeApi("napi_add_env_cleanup_hook", napi_add_env_cleanup_hook);
    loadNodeApi("napi_remove_env_cleanup_hook", napi_remove_env_cleanup_hook);
    loadNodeApi("napi_open_callback_scope", napi_open_callback_scope);
    loadNodeApi("napi_close_callback_scope", napi_close_callback_scope);
    loadNodeApi("napi_create_threadsafe_function", napi_create_threadsafe_function);
    loadNodeApi("napi_get_threadsafe_function_context", napi_get_threadsafe_function_context);
    loadNodeApi("napi_call_threadsafe_function", napi_call_threadsafe_function);
    loadNodeApi("napi_acquire_threadsafe_function", napi_acquire_threadsafe_function);
    loadNodeApi("napi_release_threadsafe_function", napi_release_threadsafe_function);
    loadNodeApi("napi_unref_threadsafe_function", napi_unref_threadsafe_function);
    loadNodeApi("napi_ref_threadsafe_function", napi_ref_threadsafe_function);
    loadNodeApi("napi_create_date", napi_create_date);
    loadNodeApi("napi_is_date", napi_is_date);
    loadNodeApi("napi_get_date_value", napi_get_date_value);
    loadNodeApi("napi_add_finalizer", napi_add_finalizer);
    loadNodeApi("napi_create_bigint_int64", napi_create_bigint_int64);
    loadNodeApi("napi_create_bigint_uint64", napi_create_bigint_uint64);
    loadNodeApi("napi_create_bigint_words", napi_create_bigint_words);
    loadNodeApi("napi_get_value_bigint_int64", napi_get_value_bigint_int64);
    loadNodeApi("napi_get_value_bigint_uint64", napi_get_value_bigint_uint64);
    loadNodeApi("napi_get_value_bigint_words", napi_get_value_bigint_words);
    loadNodeApi("napi_get_all_property_names", napi_get_all_property_names);
    loadNodeApi("napi_set_instance_data", napi_set_instance_data);
    loadNodeApi("napi_get_instance_data", napi_get_instance_data);
    loadNodeApi("napi_detach_arraybuffer", napi_detach_arraybuffer);
    loadNodeApi("napi_is_detached_arraybuffer", napi_is_detached_arraybuffer);
    loadNodeApi("napi_type_tag_object", napi_type_tag_object);
    loadNodeApi("napi_check_object_type_tag", napi_check_object_type_tag);
    loadNodeApi("napi_object_freeze", napi_object_freeze);
    loadNodeApi("napi_object_seal", napi_object_seal);
    loadNodeApi("napi_add_async_cleanup_hook", napi_add_async_cleanup_hook);
    loadNodeApi("napi_remove_async_cleanup_hook", napi_remove_async_cleanup_hook);
    loadNodeApi("node_api_symbol_for", node_api_symbol_for);
    loadNodeApi("node_api_create_syntax_error", node_api_create_syntax_error);
    loadNodeApi("node_api_throw_syntax_error", node_api_throw_syntax_error);
    loadNodeApi("node_api_get_module_file_name", node_api_get_module_file_name);
    loadNodeApi("node_api_create_external_string_latin1", node_api_create_external_string_latin1);
    loadNodeApi("node_api_create_external_string_utf16", node_api_create_external_string_utf16);
    loadNodeApi("node_api_create_property_key_latin1", node_api_create_property_key_latin1);
    loadNodeApi("node_api_create_property_key_utf8", node_api_create_property_key_utf8);
    loadNodeApi("node_api_create_property_key_utf16", node_api_create_property_key_utf16);
    loadNodeApi("node_api_create_buffer_from_arraybuffer", node_api_create_buffer_from_arraybuffer);
    loadNodeApi("node_api_post_finalizer", node_api_post_finalizer);
    loadNodeApi("napi_create_object_with_properties", napi_create_object_with_properties);
}
pub fn napi_get_last_error_info(arg0: node_api_basic_env, arg1: [*c][*c]const napi_extended_error_info) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, [*c][*c]const napi_extended_error_info) callconv(.c) napi_status;
    return callNodeApi("napi_get_last_error_info", Fn, .{ arg0, arg1 });
}
pub fn napi_get_undefined(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_undefined", Fn, .{ arg0, arg1 });
}
pub fn napi_get_null(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_null", Fn, .{ arg0, arg1 });
}
pub fn napi_get_global(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_global", Fn, .{ arg0, arg1 });
}
pub fn napi_get_boolean(arg0: napi_env, arg1: bool, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, bool, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_boolean", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_object(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_object", Fn, .{ arg0, arg1 });
}
pub fn napi_create_array(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_array", Fn, .{ arg0, arg1 });
}
pub fn napi_create_array_with_length(arg0: napi_env, arg1: usize, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_array_with_length", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_double(arg0: napi_env, arg1: f64, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, f64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_double", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_int32(arg0: napi_env, arg1: i32, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, i32, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_int32", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_uint32(arg0: napi_env, arg1: u32, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, u32, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_uint32", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_int64(arg0: napi_env, arg1: i64, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, i64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_int64", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_string_latin1(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_string_latin1", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_string_utf8(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_string_utf8", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_string_utf16(arg0: napi_env, arg1: [*c]const u16, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u16, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_string_utf16", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_symbol(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_symbol", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_function(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: napi_callback, arg4: ?*anyopaque, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, napi_callback, ?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_function", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_create_error(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_error", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_type_error(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_type_error", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_range_error(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_range_error", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_typeof(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_valuetype) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_valuetype) callconv(.c) napi_status;
    return callNodeApi("napi_typeof", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_double(arg0: napi_env, arg1: napi_value, arg2: [*c]f64) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]f64) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_double", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_int32(arg0: napi_env, arg1: napi_value, arg2: [*c]i32) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]i32) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_int32", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_uint32(arg0: napi_env, arg1: napi_value, arg2: [*c]u32) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u32) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_uint32", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_int64(arg0: napi_env, arg1: napi_value, arg2: [*c]i64) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]i64) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_int64", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_bool(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_bool", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_value_string_latin1(arg0: napi_env, arg1: napi_value, arg2: [*c]u8, arg3: usize, arg4: ?*usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u8, usize, ?*usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_string_latin1", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_get_value_string_utf8(arg0: napi_env, arg1: napi_value, arg2: [*c]u8, arg3: usize, arg4: ?*usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u8, usize, ?*usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_string_utf8", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_get_value_string_utf16(arg0: napi_env, arg1: napi_value, arg2: [*c]u16, arg3: usize, arg4: ?*usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u16, usize, ?*usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_string_utf16", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_coerce_to_bool(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_coerce_to_bool", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_coerce_to_number(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_coerce_to_number", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_coerce_to_object(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_coerce_to_object", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_coerce_to_string(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_coerce_to_string", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_prototype(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_prototype", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_property_names(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_property_names", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_set_property(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_set_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_has_property(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_has_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_property(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_delete_property(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_delete_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_has_own_property(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_has_own_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_set_named_property(arg0: napi_env, arg1: napi_value, arg2: [*c]const u8, arg3: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const u8, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_set_named_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_has_named_property(arg0: napi_env, arg1: napi_value, arg2: [*c]const u8, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const u8, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_has_named_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_named_property(arg0: napi_env, arg1: napi_value, arg2: [*c]const u8, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const u8, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_named_property", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_set_element(arg0: napi_env, arg1: napi_value, arg2: u32, arg3: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, u32, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_set_element", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_has_element(arg0: napi_env, arg1: napi_value, arg2: u32, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, u32, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_has_element", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_element(arg0: napi_env, arg1: napi_value, arg2: u32, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, u32, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_element", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_delete_element(arg0: napi_env, arg1: napi_value, arg2: u32, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, u32, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_delete_element", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_define_properties(arg0: napi_env, arg1: napi_value, arg2: usize, arg3: [*c]const napi_property_descriptor) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, usize, [*c]const napi_property_descriptor) callconv(.c) napi_status;
    return callNodeApi("napi_define_properties", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_is_array(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_array", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_array_length(arg0: napi_env, arg1: napi_value, arg2: [*c]u32) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u32) callconv(.c) napi_status;
    return callNodeApi("napi_get_array_length", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_strict_equals(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_strict_equals", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_call_function(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: usize, arg4: [*c]const napi_value, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, usize, [*c]const napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_call_function", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_new_instance(arg0: napi_env, arg1: napi_value, arg2: usize, arg3: [*c]const napi_value, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, usize, [*c]const napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_new_instance", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_instanceof(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_instanceof", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_cb_info(arg0: napi_env, arg1: napi_callback_info, arg2: ?*usize, arg3: [*c]napi_value, arg4: [*c]napi_value, arg5: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_callback_info, ?*usize, [*c]napi_value, [*c]napi_value, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_get_cb_info", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_get_new_target(arg0: napi_env, arg1: napi_callback_info, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_callback_info, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_new_target", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_define_class(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: napi_callback, arg4: ?*anyopaque, arg5: usize, arg6: [*c]const napi_property_descriptor, arg7: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, napi_callback, ?*anyopaque, usize, [*c]const napi_property_descriptor, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_define_class", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7 });
}
pub fn napi_wrap(arg0: napi_env, arg1: napi_value, arg2: ?*anyopaque, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_ref) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, ?*anyopaque, node_api_basic_finalize, ?*anyopaque, [*c]napi_ref) callconv(.c) napi_status;
    return callNodeApi("napi_wrap", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_unwrap(arg0: napi_env, arg1: napi_value, arg2: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_unwrap", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_remove_wrap(arg0: napi_env, arg1: napi_value, arg2: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_remove_wrap", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_external(arg0: napi_env, arg1: ?*anyopaque, arg2: node_api_basic_finalize, arg3: ?*anyopaque, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, ?*anyopaque, node_api_basic_finalize, ?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_external", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_get_value_external(arg0: napi_env, arg1: napi_value, arg2: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_external", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_reference(arg0: napi_env, arg1: napi_value, arg2: u32, arg3: [*c]napi_ref) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, u32, [*c]napi_ref) callconv(.c) napi_status;
    return callNodeApi("napi_create_reference", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_delete_reference(arg0: node_api_basic_env, arg1: napi_ref) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_ref) callconv(.c) napi_status;
    return callNodeApi("napi_delete_reference", Fn, .{ arg0, arg1 });
}
pub fn napi_reference_ref(arg0: napi_env, arg1: napi_ref, arg2: [*c]u32) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_ref, [*c]u32) callconv(.c) napi_status;
    return callNodeApi("napi_reference_ref", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_reference_unref(arg0: napi_env, arg1: napi_ref, arg2: [*c]u32) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_ref, [*c]u32) callconv(.c) napi_status;
    return callNodeApi("napi_reference_unref", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_reference_value(arg0: napi_env, arg1: napi_ref, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_ref, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_reference_value", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_open_handle_scope(arg0: napi_env, arg1: [*c]napi_handle_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_handle_scope) callconv(.c) napi_status;
    return callNodeApi("napi_open_handle_scope", Fn, .{ arg0, arg1 });
}
pub fn napi_close_handle_scope(arg0: napi_env, arg1: napi_handle_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_handle_scope) callconv(.c) napi_status;
    return callNodeApi("napi_close_handle_scope", Fn, .{ arg0, arg1 });
}
pub fn napi_open_escapable_handle_scope(arg0: napi_env, arg1: [*c]napi_escapable_handle_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_escapable_handle_scope) callconv(.c) napi_status;
    return callNodeApi("napi_open_escapable_handle_scope", Fn, .{ arg0, arg1 });
}
pub fn napi_close_escapable_handle_scope(arg0: napi_env, arg1: napi_escapable_handle_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_escapable_handle_scope) callconv(.c) napi_status;
    return callNodeApi("napi_close_escapable_handle_scope", Fn, .{ arg0, arg1 });
}
pub fn napi_escape_handle(arg0: napi_env, arg1: napi_escapable_handle_scope, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_escapable_handle_scope, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_escape_handle", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_throw(arg0: napi_env, arg1: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_throw", Fn, .{ arg0, arg1 });
}
pub fn napi_throw_error(arg0: napi_env, arg1: [*c]const u8, arg2: [*c]const u8) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, [*c]const u8) callconv(.c) napi_status;
    return callNodeApi("napi_throw_error", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_throw_type_error(arg0: napi_env, arg1: [*c]const u8, arg2: [*c]const u8) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, [*c]const u8) callconv(.c) napi_status;
    return callNodeApi("napi_throw_type_error", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_throw_range_error(arg0: napi_env, arg1: [*c]const u8, arg2: [*c]const u8) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, [*c]const u8) callconv(.c) napi_status;
    return callNodeApi("napi_throw_range_error", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_is_error(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_error", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_is_exception_pending(arg0: napi_env, arg1: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_exception_pending", Fn, .{ arg0, arg1 });
}
pub fn napi_get_and_clear_last_exception(arg0: napi_env, arg1: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_and_clear_last_exception", Fn, .{ arg0, arg1 });
}
pub fn napi_is_arraybuffer(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_arraybuffer", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_arraybuffer(arg0: napi_env, arg1: usize, arg2: [*c]?*anyopaque, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, [*c]?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_arraybuffer", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_external_arraybuffer(arg0: napi_env, arg1: ?*anyopaque, arg2: usize, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, ?*anyopaque, usize, node_api_basic_finalize, ?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_external_arraybuffer", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_get_arraybuffer_info(arg0: napi_env, arg1: napi_value, arg2: [*c]?*anyopaque, arg3: [*c]usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]?*anyopaque, [*c]usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_arraybuffer_info", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_is_typedarray(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_typedarray", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_typedarray(arg0: napi_env, arg1: napi_typedarray_type, arg2: usize, arg3: napi_value, arg4: usize, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_typedarray_type, usize, napi_value, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_typedarray", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_get_typedarray_info(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_typedarray_type, arg3: [*c]usize, arg4: [*c]?*anyopaque, arg5: [*c]napi_value, arg6: [*c]usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_typedarray_type, [*c]usize, [*c]?*anyopaque, [*c]napi_value, [*c]usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_typedarray_info", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6 });
}
pub fn napi_create_dataview(arg0: napi_env, arg1: usize, arg2: napi_value, arg3: usize, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, napi_value, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_dataview", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_is_dataview(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_dataview", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_dataview_info(arg0: napi_env, arg1: napi_value, arg2: [*c]usize, arg3: [*c]?*anyopaque, arg4: [*c]napi_value, arg5: [*c]usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]usize, [*c]?*anyopaque, [*c]napi_value, [*c]usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_dataview_info", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_get_version(arg0: node_api_basic_env, arg1: [*c]u32) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, [*c]u32) callconv(.c) napi_status;
    return callNodeApi("napi_get_version", Fn, .{ arg0, arg1 });
}
pub fn napi_create_promise(arg0: napi_env, arg1: [*c]napi_deferred, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]napi_deferred, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_promise", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_resolve_deferred(arg0: napi_env, arg1: napi_deferred, arg2: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_deferred, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_resolve_deferred", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_reject_deferred(arg0: napi_env, arg1: napi_deferred, arg2: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_deferred, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_reject_deferred", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_is_promise(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_promise", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_run_script(arg0: napi_env, arg1: napi_value, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_run_script", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_adjust_external_memory(arg0: node_api_basic_env, arg1: i64, arg2: [*c]i64) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, i64, [*c]i64) callconv(.c) napi_status;
    return callNodeApi("napi_adjust_external_memory", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_module_register(arg0: [*c]napi_module) callconv(.c) void {
    const Fn = *const fn ([*c]napi_module) callconv(.c) void;
    return callNodeApi("napi_module_register", Fn, .{arg0});
}
pub fn napi_fatal_error(arg0: [*c]const u8, arg1: usize, arg2: [*c]const u8, arg3: usize) callconv(.c) noreturn {
    const Fn = *const fn ([*c]const u8, usize, [*c]const u8, usize) callconv(.c) noreturn;
    return callNodeApi("napi_fatal_error", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_async_init(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_async_context) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_async_context) callconv(.c) napi_status;
    return callNodeApi("napi_async_init", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_async_destroy(arg0: napi_env, arg1: napi_async_context) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_async_context) callconv(.c) napi_status;
    return callNodeApi("napi_async_destroy", Fn, .{ arg0, arg1 });
}
pub fn napi_make_callback(arg0: napi_env, arg1: napi_async_context, arg2: napi_value, arg3: napi_value, arg4: usize, arg5: [*c]const napi_value, arg6: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_async_context, napi_value, napi_value, usize, [*c]const napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_make_callback", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6 });
}
pub fn napi_create_buffer(arg0: napi_env, arg1: usize, arg2: [*c]?*anyopaque, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, [*c]?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_buffer", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_external_buffer(arg0: napi_env, arg1: usize, arg2: ?*anyopaque, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, ?*anyopaque, node_api_basic_finalize, ?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_external_buffer", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_create_buffer_copy(arg0: napi_env, arg1: usize, arg2: ?*const anyopaque, arg3: [*c]?*anyopaque, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, usize, ?*const anyopaque, [*c]?*anyopaque, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_buffer_copy", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_is_buffer(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_buffer", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_buffer_info(arg0: napi_env, arg1: napi_value, arg2: [*c]?*anyopaque, arg3: [*c]usize) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]?*anyopaque, [*c]usize) callconv(.c) napi_status;
    return callNodeApi("napi_get_buffer_info", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_async_work(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: napi_async_execute_callback, arg4: napi_async_complete_callback, arg5: ?*anyopaque, arg6: [*c]napi_async_work) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, napi_async_execute_callback, napi_async_complete_callback, ?*anyopaque, [*c]napi_async_work) callconv(.c) napi_status;
    return callNodeApi("napi_create_async_work", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6 });
}
pub fn napi_delete_async_work(arg0: napi_env, arg1: napi_async_work) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_async_work) callconv(.c) napi_status;
    return callNodeApi("napi_delete_async_work", Fn, .{ arg0, arg1 });
}
pub fn napi_queue_async_work(arg0: node_api_basic_env, arg1: napi_async_work) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_async_work) callconv(.c) napi_status;
    return callNodeApi("napi_queue_async_work", Fn, .{ arg0, arg1 });
}
pub fn napi_cancel_async_work(arg0: node_api_basic_env, arg1: napi_async_work) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_async_work) callconv(.c) napi_status;
    return callNodeApi("napi_cancel_async_work", Fn, .{ arg0, arg1 });
}
pub fn napi_get_node_version(arg0: node_api_basic_env, arg1: [*c][*c]const napi_node_version) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, [*c][*c]const napi_node_version) callconv(.c) napi_status;
    return callNodeApi("napi_get_node_version", Fn, .{ arg0, arg1 });
}

pub fn napi_fatal_exception(arg0: napi_env, arg1: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_fatal_exception", Fn, .{ arg0, arg1 });
}
pub fn napi_add_env_cleanup_hook(arg0: node_api_basic_env, arg1: napi_cleanup_hook, arg2: ?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_cleanup_hook, ?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_add_env_cleanup_hook", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_remove_env_cleanup_hook(arg0: node_api_basic_env, arg1: napi_cleanup_hook, arg2: ?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_cleanup_hook, ?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_remove_env_cleanup_hook", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_open_callback_scope(arg0: napi_env, arg1: napi_value, arg2: napi_async_context, arg3: [*c]napi_callback_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_async_context, [*c]napi_callback_scope) callconv(.c) napi_status;
    return callNodeApi("napi_open_callback_scope", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_close_callback_scope(arg0: napi_env, arg1: napi_callback_scope) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_callback_scope) callconv(.c) napi_status;
    return callNodeApi("napi_close_callback_scope", Fn, .{ arg0, arg1 });
}

pub const napi_threadsafe_function__ = opaque {};
pub const napi_threadsafe_function = ?*napi_threadsafe_function__;
pub const napi_threadsafe_function_release_mode = c_int;
pub const napi_tsfn_release: napi_threadsafe_function_release_mode = 0;
pub const napi_tsfn_abort: napi_threadsafe_function_release_mode = 1;
pub const napi_threadsafe_function_call_mode = c_int;
pub const napi_tsfn_nonblocking: napi_threadsafe_function_call_mode = 0;
pub const napi_tsfn_blocking: napi_threadsafe_function_call_mode = 1;
pub const napi_threadsafe_function_call_js = ?*const fn (env: napi_env, js_callback: napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void;

pub fn napi_create_threadsafe_function(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: napi_value, arg4: usize, arg5: usize, arg6: ?*anyopaque, arg7: napi_finalize, arg8: ?*anyopaque, arg9: napi_threadsafe_function_call_js, arg10: [*c]napi_threadsafe_function) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, napi_value, usize, usize, ?*anyopaque, napi_finalize, ?*anyopaque, napi_threadsafe_function_call_js, [*c]napi_threadsafe_function) callconv(.c) napi_status;
    return callNodeApi("napi_create_threadsafe_function", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10 });
}
pub fn napi_get_threadsafe_function_context(arg0: napi_threadsafe_function, arg1: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (napi_threadsafe_function, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_get_threadsafe_function_context", Fn, .{ arg0, arg1 });
}
pub fn napi_call_threadsafe_function(arg0: napi_threadsafe_function, arg1: ?*anyopaque, arg2: napi_threadsafe_function_call_mode) callconv(.c) napi_status {
    const Fn = *const fn (napi_threadsafe_function, ?*anyopaque, napi_threadsafe_function_call_mode) callconv(.c) napi_status;
    return callNodeApi("napi_call_threadsafe_function", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_acquire_threadsafe_function(arg0: napi_threadsafe_function) callconv(.c) napi_status {
    const Fn = *const fn (napi_threadsafe_function) callconv(.c) napi_status;
    return callNodeApi("napi_acquire_threadsafe_function", Fn, .{arg0});
}
pub fn napi_release_threadsafe_function(arg0: napi_threadsafe_function, arg1: napi_threadsafe_function_release_mode) callconv(.c) napi_status {
    const Fn = *const fn (napi_threadsafe_function, napi_threadsafe_function_release_mode) callconv(.c) napi_status;
    return callNodeApi("napi_release_threadsafe_function", Fn, .{ arg0, arg1 });
}
pub fn napi_unref_threadsafe_function(arg0: node_api_basic_env, arg1: napi_threadsafe_function) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_threadsafe_function) callconv(.c) napi_status;
    return callNodeApi("napi_unref_threadsafe_function", Fn, .{ arg0, arg1 });
}
pub fn napi_ref_threadsafe_function(arg0: node_api_basic_env, arg1: napi_threadsafe_function) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_threadsafe_function) callconv(.c) napi_status;
    return callNodeApi("napi_ref_threadsafe_function", Fn, .{ arg0, arg1 });
}

pub fn napi_create_date(arg0: napi_env, arg1: f64, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, f64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_date", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_is_date(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_date", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_get_date_value(arg0: napi_env, arg1: napi_value, arg2: [*c]f64) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]f64) callconv(.c) napi_status;
    return callNodeApi("napi_get_date_value", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_add_finalizer(arg0: napi_env, arg1: napi_value, arg2: ?*anyopaque, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_ref) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, ?*anyopaque, node_api_basic_finalize, ?*anyopaque, [*c]napi_ref) callconv(.c) napi_status;
    return callNodeApi("napi_add_finalizer", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}

pub const napi_bigint: napi_valuetype = 9;
pub const napi_bigint64_array: napi_typedarray_type = 9;
pub const napi_biguint64_array: napi_typedarray_type = 10;
pub const napi_key_collection_mode = c_int;
pub const napi_key_include_prototypes: napi_key_collection_mode = 0;
pub const napi_key_own_only: napi_key_collection_mode = 1;
pub const napi_key_filter = c_int;
pub const napi_key_all_properties: napi_key_filter = 0;
pub const napi_key_writable: napi_key_filter = 1;
pub const napi_key_enumerable: napi_key_filter = 1 << 1;
pub const napi_key_configurable: napi_key_filter = 1 << 2;
pub const napi_key_skip_strings: napi_key_filter = 1 << 3;
pub const napi_key_skip_symbols: napi_key_filter = 1 << 4;
pub const napi_key_conversion = c_int;
pub const napi_key_keep_numbers: napi_key_conversion = 0;
pub const napi_key_numbers_to_strings: napi_key_conversion = 1;

pub fn napi_create_bigint_int64(arg0: napi_env, arg1: i64, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, i64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_bigint_int64", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_bigint_uint64(arg0: napi_env, arg1: u64, arg2: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, u64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_bigint_uint64", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_create_bigint_words(arg0: napi_env, arg1: c_int, arg2: usize, arg3: [*c]const u64, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, c_int, usize, [*c]const u64, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_bigint_words", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_get_value_bigint_int64(arg0: napi_env, arg1: napi_value, arg2: [*c]i64, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]i64, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_bigint_int64", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_value_bigint_uint64(arg0: napi_env, arg1: napi_value, arg2: [*c]u64, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]u64, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_bigint_uint64", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_value_bigint_words(arg0: napi_env, arg1: napi_value, arg2: [*c]c_int, arg3: [*c]usize, arg4: [*c]u64) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]c_int, [*c]usize, [*c]u64) callconv(.c) napi_status;
    return callNodeApi("napi_get_value_bigint_words", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}
pub fn napi_get_all_property_names(arg0: napi_env, arg1: napi_value, arg2: napi_key_collection_mode, arg3: napi_key_filter, arg4: napi_key_conversion, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_key_collection_mode, napi_key_filter, napi_key_conversion, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_get_all_property_names", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
pub fn napi_set_instance_data(arg0: node_api_basic_env, arg1: ?*anyopaque, arg2: napi_finalize, arg3: ?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, ?*anyopaque, napi_finalize, ?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_set_instance_data", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_get_instance_data(arg0: node_api_basic_env, arg1: [*c]?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, [*c]?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("napi_get_instance_data", Fn, .{ arg0, arg1 });
}

pub fn napi_detach_arraybuffer(arg0: napi_env, arg1: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_detach_arraybuffer", Fn, .{ arg0, arg1 });
}
pub fn napi_is_detached_arraybuffer(arg0: napi_env, arg1: napi_value, arg2: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_is_detached_arraybuffer", Fn, .{ arg0, arg1, arg2 });
}

pub const napi_type_tag = extern struct {
    lower: u64,
    upper: u64,
};
pub const napi_async_cleanup_hook_handle__ = opaque {};
pub const napi_async_cleanup_hook_handle = ?*napi_async_cleanup_hook_handle__;
pub const napi_async_cleanup_hook = ?*const fn (handle: napi_async_cleanup_hook_handle, data: ?*anyopaque) callconv(.c) void;

pub fn napi_type_tag_object(arg0: napi_env, arg1: napi_value, arg2: [*c]const napi_type_tag) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const napi_type_tag) callconv(.c) napi_status;
    return callNodeApi("napi_type_tag_object", Fn, .{ arg0, arg1, arg2 });
}
pub fn napi_check_object_type_tag(arg0: napi_env, arg1: napi_value, arg2: [*c]const napi_type_tag, arg3: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const napi_type_tag, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("napi_check_object_type_tag", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_object_freeze(arg0: napi_env, arg1: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_object_freeze", Fn, .{ arg0, arg1 });
}
pub fn napi_object_seal(arg0: napi_env, arg1: napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_object_seal", Fn, .{ arg0, arg1 });
}
pub fn napi_add_async_cleanup_hook(arg0: node_api_basic_env, arg1: napi_async_cleanup_hook, arg2: ?*anyopaque, arg3: [*c]napi_async_cleanup_hook_handle) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_async_cleanup_hook, ?*anyopaque, [*c]napi_async_cleanup_hook_handle) callconv(.c) napi_status;
    return callNodeApi("napi_add_async_cleanup_hook", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_remove_async_cleanup_hook(arg0: napi_async_cleanup_hook_handle) callconv(.c) napi_status {
    const Fn = *const fn (napi_async_cleanup_hook_handle) callconv(.c) napi_status;
    return callNodeApi("napi_remove_async_cleanup_hook", Fn, .{arg0});
}

pub fn node_api_symbol_for(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_symbol_for", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn node_api_create_syntax_error(arg0: napi_env, arg1: napi_value, arg2: napi_value, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, napi_value, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_create_syntax_error", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn node_api_throw_syntax_error(arg0: napi_env, arg1: [*c]const u8, arg2: [*c]const u8) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, [*c]const u8) callconv(.c) napi_status;
    return callNodeApi("node_api_throw_syntax_error", Fn, .{ arg0, arg1, arg2 });
}
pub fn node_api_get_module_file_name(arg0: node_api_basic_env, arg1: [*c][*c]const u8) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, [*c][*c]const u8) callconv(.c) napi_status;
    return callNodeApi("node_api_get_module_file_name", Fn, .{ arg0, arg1 });
}

pub fn node_api_create_external_string_latin1(arg0: napi_env, arg1: [*c]u8, arg2: usize, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_value, arg6: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]u8, usize, node_api_basic_finalize, ?*anyopaque, [*c]napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("node_api_create_external_string_latin1", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6 });
}
pub fn node_api_create_external_string_utf16(arg0: napi_env, arg1: [*c]u16, arg2: usize, arg3: node_api_basic_finalize, arg4: ?*anyopaque, arg5: [*c]napi_value, arg6: [*c]bool) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]u16, usize, node_api_basic_finalize, ?*anyopaque, [*c]napi_value, [*c]bool) callconv(.c) napi_status;
    return callNodeApi("node_api_create_external_string_utf16", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5, arg6 });
}
pub fn node_api_create_property_key_latin1(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_create_property_key_latin1", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn node_api_create_property_key_utf8(arg0: napi_env, arg1: [*c]const u8, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u8, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_create_property_key_utf8", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn node_api_create_property_key_utf16(arg0: napi_env, arg1: [*c]const u16, arg2: usize, arg3: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, [*c]const u16, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_create_property_key_utf16", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn node_api_create_buffer_from_arraybuffer(arg0: napi_env, arg1: napi_value, arg2: usize, arg3: usize, arg4: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, usize, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("node_api_create_buffer_from_arraybuffer", Fn, .{ arg0, arg1, arg2, arg3, arg4 });
}

pub fn node_api_post_finalizer(arg0: node_api_basic_env, arg1: napi_finalize, arg2: ?*anyopaque, arg3: ?*anyopaque) callconv(.c) napi_status {
    const Fn = *const fn (node_api_basic_env, napi_finalize, ?*anyopaque, ?*anyopaque) callconv(.c) napi_status;
    return callNodeApi("node_api_post_finalizer", Fn, .{ arg0, arg1, arg2, arg3 });
}
pub fn napi_create_object_with_properties(arg0: napi_env, arg1: napi_value, arg2: [*c]const napi_value, arg3: [*c]const napi_value, arg4: usize, arg5: [*c]napi_value) callconv(.c) napi_status {
    const Fn = *const fn (napi_env, napi_value, [*c]const napi_value, [*c]const napi_value, usize, [*c]napi_value) callconv(.c) napi_status;
    return callNodeApi("napi_create_object_with_properties", Fn, .{ arg0, arg1, arg2, arg3, arg4, arg5 });
}
