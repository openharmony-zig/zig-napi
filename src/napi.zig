const std = @import("std");

// 导入Node.js N-API
pub const c = @cImport({
    @cInclude("napi/native_api.h");
});

/// 全局函数注册表 - 使用编译时注册
pub const Registry = struct {
    const MAX_FUNCTIONS = 256;
    var functions: [MAX_FUNCTIONS]FunctionInfo = undefined;
    var count: usize = 0;
};

/// 函数信息结构
pub const FunctionInfo = struct {
    name: []const u8,
    wrapper: *const fn (env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value,
};

/// 错误处理
pub fn checkStatus(env: c.napi_env, status: c.napi_status) !void {
    if (status != c.napi_ok) {
        var error_info: c.napi_extended_error_info = undefined;
        _ = c.napi_get_last_error_info(env, &error_info);
        std.debug.print("NAPI Error: {s}\n", .{error_info.error_message});
        return error.NapiError;
    }
}

/// 创建JavaScript错误
fn createJsError(env: c.napi_env, message: []const u8) c.napi_value {
    var err_msg: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, message.ptr, message.len, &err_msg);

    var error_obj: c.napi_value = undefined;
    _ = c.napi_create_error(env, null, err_msg, &error_obj);

    _ = c.napi_throw(env, error_obj);

    var undefined_val: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undefined_val);
    return undefined_val;
}

/// Zig值转JavaScript值
fn zigToJs(env: c.napi_env, value: anytype) !c.napi_value {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .Void => {
            var result: c.napi_value = undefined;
            try checkStatus(env, c.napi_get_undefined(env, &result));
            return result;
        },
        .Bool => {
            var result: c.napi_value = undefined;
            try checkStatus(env, c.napi_get_boolean(env, value, &result));
            return result;
        },
        .Int, .ComptimeInt => {
            var result: c.napi_value = undefined;
            try checkStatus(env, c.napi_create_int64(env, @as(i64, value), &result));
            return result;
        },
        .Float, .ComptimeFloat => {
            var result: c.napi_value = undefined;
            try checkStatus(env, c.napi_create_double(env, value, &result));
            return result;
        },
        .Pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                var result: c.napi_value = undefined;
                try checkStatus(env, c.napi_create_string_utf8(env, value.ptr, value.len, &result));
                return result;
            }
            @compileError("不支持的指针类型");
        },
        else => @compileError("不支持的类型转换为JS值"),
    }
}

/// JavaScript值转Zig值
fn jsToZig(env: c.napi_env, js_value: c.napi_value, comptime T: type, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .Bool => {
            var result: bool = undefined;
            try checkStatus(env, c.napi_get_value_bool(env, js_value, &result));
            return result;
        },
        .Int => |int_info| {
            if (int_info.bits <= 32) {
                var result: i32 = undefined;
                try checkStatus(env, c.napi_get_value_int32(env, js_value, &result));
                return @intCast(result);
            } else {
                var result: i64 = undefined;
                try checkStatus(env, c.napi_get_value_int64(env, js_value, &result));
                return @intCast(result);
            }
        },
        .Float => {
            var result: f64 = undefined;
            try checkStatus(env, c.napi_get_value_double(env, js_value, &result));
            return @floatCast(result);
        },
        .Pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                // 获取字符串长度
                var str_len: usize = undefined;
                try checkStatus(env, c.napi_get_value_string_utf8(env, js_value, null, 0, &str_len));

                // 分配内存
                var buf = try allocator.alloc(u8, str_len + 1);

                // 获取字符串内容
                try checkStatus(env, c.napi_get_value_string_utf8(env, js_value, buf.ptr, buf.len, &str_len));

                return buf[0..str_len];
            }
            @compileError("不支持的指针类型");
        },
        else => @compileError("不支持的JS值转换为Zig类型"),
    }
}

/// 核心简化的NAPI注册函数 - 使用声明式语法
pub fn napi(comptime func: anytype) void {
    const func_name = @typeName(@TypeOf(func));

    // 提取函数名 (移除命名空间前缀和类型信息)
    var name_start: usize = 0;
    const name_end: usize = func_name.len;

    // 找到最后一个点后面的字符
    for (0..func_name.len) |i| {
        if (func_name[i] == '.') {
            name_start = i + 1;
        }
    }

    // 获取纯函数名
    const pure_name = func_name[name_start..name_end];

    // 创建包装器结构体
    const Wrapper = struct {
        pub fn wrapper(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
            // 获取函数元数据
            const FuncType = @TypeOf(func);
            const func_info = @typeInfo(FuncType).Fn;
            const args_count = func_info.params.len;
            const ReturnType = func_info.return_type.?;

            // 临时分配器
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // 获取JS参数
            var js_args: [16]c.napi_value = undefined; // 支持最多16个参数
            var received_args: usize = args_count;
            var this_obj: c.napi_value = undefined;

            if (c.napi_get_cb_info(env, info, &received_args, if (args_count > 0) &js_args else null, &this_obj, null) != c.napi_ok) {
                return createJsError(env, "无法获取函数参数");
            }

            // 检查参数数量
            if (received_args < args_count) {
                return createJsError(env, "参数不足");
            }

            // 创建参数元组并解析参数
            const ArgsTuple = std.meta.ArgsTuple(FuncType);
            var args: ArgsTuple = undefined;

            comptime var i = 0;
            inline while (i < args_count) : (i += 1) {
                const ParamType = func_info.params[i].type.?;
                args[i] = jsToZig(env, js_args[i], ParamType, allocator) catch |err| {
                    return createJsError(env, @errorName(err));
                };
            }

            // 调用函数并处理结果
            if (@typeInfo(ReturnType) == .ErrorUnion) {
                // 可能出错的函数
                const result = @call(.auto, func, args) catch |err| {
                    return createJsError(env, @errorName(err));
                };

                return zigToJs(env, result) catch |err| {
                    return createJsError(env, @errorName(err));
                };
            } else {
                // 普通函数
                const result = @call(.auto, func, args);
                return zigToJs(env, result) catch |err| {
                    return createJsError(env, @errorName(err));
                };
            }
        }
    };

    // 编译时注册函数
    comptime {
        if (Registry.count >= Registry.MAX_FUNCTIONS) {
            @compileError("超出最大函数注册数量");
        }

        Registry.functions[Registry.count] = .{
            .name = pure_name,
            .wrapper = &Wrapper.wrapper,
        };
        Registry.count += 1;
    }
}

/// 导出所有注册的函数
pub fn exportAll(env: c.napi_env, exports: c.napi_value) !void {
    var i: usize = 0;
    while (i < Registry.count) : (i += 1) {
        const func = Registry.functions[i];

        var napi_func: c.napi_value = undefined;
        try checkStatus(env, c.napi_create_function(env, func.name.ptr, func.name.len, func.wrapper, null, &napi_func));

        try checkStatus(env, c.napi_set_named_property(env, exports, func.name.ptr, napi_func));
    }
}

/// 注册模块导出函数 - 为了在模块初始化时使用
pub fn registerModule(env: c.napi_env, exports: c.napi_value) c.napi_value {
    exportAll(env, exports) catch |err| {
        std.debug.print("注册NAPI函数失败: {}\n", .{err});
    };
    return exports;
}
