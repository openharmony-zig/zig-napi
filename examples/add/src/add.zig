const std = @import("std");
const napi = @cImport({
    @cInclude("napi/native_api.h");
});

// Add 函数实现
fn add(env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value {
    var argc: usize = 2;
    var args: [2]napi.napi_value = undefined;

    // 获取参数
    _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);

    // 检查参数类型
    var value_type0: napi.napi_valuetype = undefined;
    var value_type1: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, args[0], &value_type0);
    _ = napi.napi_typeof(env, args[1], &value_type1);

    // 获取参数值
    var value0: f64 = undefined;
    var value1: f64 = undefined;
    _ = napi.napi_get_value_double(env, args[0], &value0);
    _ = napi.napi_get_value_double(env, args[1], &value1);

    // 创建返回值
    var result: napi.napi_value = undefined;
    _ = napi.napi_create_double(env, value0 + value1, &result);

    return result;
}

// 初始化函数
fn init(env: napi.napi_env, exports: napi.napi_value) callconv(.C) napi.napi_value {
    const desc = [_]napi.napi_property_descriptor{
        .{
            .utf8name = "add",
            .method = add,
            .getter = null,
            .setter = null,
            .value = null,
            .attributes = napi.napi_default,
            .data = null,
        },
    };

    _ = napi.napi_define_properties(env, exports, 1, &desc);

    return exports;
}

// 模块定义
var module = napi.napi_module{
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = null,
    .nm_register_func = init,
    .nm_modname = "add",
    .nm_priv = null,
    .reserved = .{ null, null, null, null },
};

fn module_init() callconv(.C) void {
    napi.napi_module_register(&module);
}

// It seems that the zig-0.13.0 does not support comptime export.
// It may work with zig-0.14.0 or newer versions which syntax is reference like `&module_init`.
// comptime {
//     @export(module_init, .{ .linkage = .strong, .name = "init_array", .section = ".init_array" });
// }

export const init_array: [1]*const fn () callconv(.C) void linksection(".init_array") = .{&module_init};
