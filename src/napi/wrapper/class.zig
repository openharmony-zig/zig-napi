const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const CallbackInfo = @import("./callback_info.zig").CallbackInfo;
const napi_env = @import("../env.zig");
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const GlobalAllocator = @import("../util/allocator.zig");

var class_constructors: std.StringHashMap(napi.napi_value) = std.StringHashMap(napi.napi_value).init(GlobalAllocator.globalAllocator());

pub fn ClassWrapper(comptime T: type, comptime HasInit: bool) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Class() only support struct type");
    }

    if (type_info.@"struct".is_tuple) {
        @compileError("Class() does not support tuple type");
    }

    const fields = type_info.@"struct".fields;
    const decls = type_info.@"struct".decls;

    const class_name = comptime helper.shortTypeName(T);
    return struct {
        const WrappedType = T;

        env: napi.napi_env,
        raw: napi.napi_value,

        const Self = @This();

        // 构造器回调
        fn constructor_callback(env: napi.napi_env, callback_info: napi.napi_callback_info) callconv(.c) napi.napi_value {
            const infos = CallbackInfo.from_raw(env, callback_info);

            const data = GlobalAllocator.globalAllocator().create(T) catch return null;

            if (@hasDecl(T, "init")) {
                var tuple_args: std.meta.ArgsTuple(T.init) = undefined;
                inline for (@typeInfo(std.meta.ArgsTuple(T.init)).@"fn".params, 0..) |arg, i| {
                    tuple_args[i] = Napi.from_napi_value(infos.env, infos.args[i].raw, arg.type.?);
                }

                data.* = @call(.auto, T.init, tuple_args) catch {
                    GlobalAllocator.globalAllocator().destroy(data);
                    return null;
                };
            } else {
                // init with zero
                data.* = std.mem.zeroes(T);
                // if HasInit, init with args with order of fields
                if (comptime HasInit) {
                    inline for (fields, 0..) |field, i| {
                        @field(data.*, field.name) = Napi.from_napi_value(infos.env, infos.args[i].raw, field.type);
                    }
                }
            }

            const this_obj = infos.This();

            var ref: napi.napi_ref = undefined;
            const status = napi.napi_wrap(env, this_obj, data, finalize_callback, null, &ref);
            if (status != napi.napi_ok) {
                GlobalAllocator.globalAllocator().destroy(data);
                return null;
            }

            var ref_count: u32 = undefined;
            _ = napi.napi_reference_unref(env, ref, &ref_count);

            return this_obj;
        }

        fn finalize_callback(env: napi.napi_env, data: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
            _ = env;
            _ = hint;

            if (data) |ptr| {
                const typed_data: *T = @ptrCast(@alignCast(ptr));
                if (@hasDecl(T, "deinit")) {
                    typed_data.deinit();
                }
                GlobalAllocator.globalAllocator().destroy(typed_data);
            }
        }

        fn define_class(env: napi.napi_env) !napi.napi_value {
            comptime var property_count: usize = 0;
            inline for (fields) |_| {
                property_count += 1;
            }
            inline for (decls) |decl| {
                if (@typeInfo(@TypeOf(@field(T, decl.name))) == .Fn and
                    !std.mem.eql(u8, decl.name, "init") and
                    !std.mem.eql(u8, decl.name, "deinit"))
                {
                    property_count += 1;
                }
            }

            var properties: [property_count]napi.napi_property_descriptor = undefined;
            var prop_idx: usize = 0;

            inline for (fields) |field| {
                const FieldAccessor = struct {
                    fn getter(getter_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                        const cb_info = CallbackInfo.from_raw(getter_env, info);
                        var data: ?*anyopaque = null;
                        _ = napi.napi_unwrap(getter_env, cb_info.This(), &data);
                        if (data == null) return null;

                        const instance: *T = @ptrCast(@alignCast(data.?));
                        const field_value = @field(instance.*, field.name);
                        return Napi.to_napi_value(getter_env, field_value, field.name) catch null;
                    }

                    fn setter(setter_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                        const cb_info = CallbackInfo.from_raw(setter_env, info);
                        var data: ?*anyopaque = null;
                        _ = napi.napi_unwrap(setter_env, cb_info.This(), &data);
                        if (data == null) return null;

                        const instance: *T = @ptrCast(@alignCast(data.?));
                        const args = cb_info.args;
                        if (args.len > 0) {
                            const new_value = Napi.from_napi_value(setter_env, args[0].raw, field.type);
                            @field(instance.*, field.name) = new_value;
                        }

                        return null;
                    }
                };

                properties[prop_idx] = napi.napi_property_descriptor{
                    .utf8name = @ptrCast(field.name.ptr),
                    .name = null,
                    .method = null,
                    .getter = FieldAccessor.getter,
                    .setter = FieldAccessor.setter,
                    .value = null,
                    .attributes = napi.napi_default,
                    .data = null,
                };
                prop_idx += 1;
            }

            inline for (decls) |decl| {
                if (@typeInfo(@TypeOf(@field(T, decl.name))) == .Fn and
                    !std.mem.eql(u8, decl.name, "init") and
                    !std.mem.eql(u8, decl.name, "deinit"))
                {
                    const method = @field(T, decl.name);
                    const method_info = @typeInfo(@TypeOf(method));
                    const params = method_info.Fn.params;
                    const is_instance_method = params.len > 0 and params[0].type.? == *T;

                    const MethodWrapper = struct {
                        fn call(method_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                            const cb_info = CallbackInfo.from_raw(method_env, info);

                            if (is_instance_method) {
                                var data: ?*anyopaque = null;
                                _ = napi.napi_unwrap(method_env, cb_info.This(), &data);
                                if (data == null) return null;

                                const instance: *T = @ptrCast(@alignCast(data.?));
                                const result = method(instance);
                                return Napi.to_napi_value(method_env, result, decl.name) catch null;
                            } else {
                                const result = method();
                                return Napi.to_napi_value(method_env, result, decl.name) catch null;
                            }
                        }
                    };

                    properties[prop_idx] = napi.napi_property_descriptor{
                        .utf8name = @ptrCast(decl.name.ptr),
                        .name = null,
                        .method = MethodWrapper.call,
                        .getter = null,
                        .setter = null,
                        .value = null,
                        .attributes = if (is_instance_method) napi.napi_default else napi.napi_static,
                        .data = null,
                    };
                    prop_idx += 1;
                }
            }

            var constructor: napi.napi_value = undefined;
            _ = napi.napi_define_class(env, class_name.ptr, class_name.len, constructor_callback, null, prop_idx, &properties, &constructor);

            try class_constructors.put(class_name, constructor);
            return constructor;
        }

        fn define_custom_method(_: napi.napi_env, _: napi.napi_value) !void {}

        /// to_napi_value will create a class constructor and return it
        pub fn to_napi_value(env: napi_env.Env) !napi.napi_value {
            const constructor = try Self.define_class(env.raw);

            try Self.define_custom_method(env.raw, constructor);

            return constructor;
        }
    };
}

/// Create a class with default constructor function
pub fn Class(comptime T: type) type {
    return ClassWrapper(T, true);
}

/// Create a class without default constructor function
pub fn ClassWithoutInit(comptime T: type) type {
    return ClassWrapper(T, false);
}

pub fn isClass(T: anytype) bool {
    const type_name = @typeName(T);

    return std.mem.indexOf(u8, type_name, "ClassWrapper") != null;
}
