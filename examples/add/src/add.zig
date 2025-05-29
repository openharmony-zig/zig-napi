const std = @import("std");
const napi = @cImport({
    @cInclude("napi/native_api.h");
});

// 定义一个函数包装器，用于自动处理参数解析和类型转换
fn wrapFn(comptime T: type, comptime func: fn (T, T) T) fn (napi.napi_env, napi.napi_callback_info) callconv(.C) napi.napi_value {
    return struct {
        fn wrapper(env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value {
            var argc: usize = 2;
            var args: [2]napi.napi_value = undefined;
            _ = napi.napi_get_cb_info(env, info, &argc, &args, null, null);

            var value0: T = undefined;
            var value1: T = undefined;
            _ = napi.napi_get_value_double(env, args[0], &value0);
            _ = napi.napi_get_value_double(env, args[1], &value1);

            var result: napi.napi_value = undefined;
            _ = napi.napi_create_double(env, func(value0, value1), &result);
            return result;
        }
    }.wrapper;
}

// 定义一个模块注册器
fn registerModule(comptime name: []const u8, comptime func: fn (f64, f64) f64) void {
    const WrappedFn = wrapFn(f64, func);

    const desc = [_]napi.napi_property_descriptor{
        .{
            .utf8name = name,
            .method = WrappedFn,
            .getter = null,
            .setter = null,
            .value = null,
            .attributes = napi.napi_default,
            .data = null,
        },
    };

    const init = struct {
        fn initFn(env: napi.napi_env, exports: napi.napi_value) callconv(.C) napi.napi_value {
            _ = napi.napi_define_properties(env, exports, 1, &desc);
            return exports;
        }
    }.initFn;

    const module = napi.napi_module{
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = null,
        .nm_register_func = init,
        .nm_modname = name,
        .nm_priv = null,
        .reserved = .{ null, null, null, null },
    };

    const module_register = struct {
        fn register() callconv(.C) void {
            napi.napi_module_register(&module);
        }
    }.register;

    comptime {
        const init_array = [1]*const fn () callconv(.C) void{&module_register};
        @export(&init_array, .{ .linkage = .strong, .name = "init_array", .section = ".init_array" });
    }
}

// 定义核心函数
fn add_impl(a: f64, b: f64) f64 {
    return cc.add(a, b);
}

// 在编译时注册模块
comptime {
    registerModule("add", add_impl);
}
