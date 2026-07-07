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
