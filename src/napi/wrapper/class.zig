const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const CallbackInfo = @import("./callback_info.zig").CallbackInfo;
const napi_env = @import("../env.zig");
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const NapiError = @import("./error.zig");
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

        fn constructor_callback(env: napi.napi_env, callback_info: napi.napi_callback_info) callconv(.c) napi.napi_value {
            const infos = CallbackInfo.from_raw(env, callback_info);

            const data = GlobalAllocator.globalAllocator().create(T) catch return null;

            if (@hasDecl(T, "init")) {
                const init_fn = T.init;
                const init_fn_type = @TypeOf(init_fn);
                const init_fn_info = @typeInfo(init_fn_type);

                var tuple_args: std.meta.ArgsTuple(init_fn_type) = undefined;
                inline for (init_fn_info.@"fn".params, 0..) |arg, i| {
                    tuple_args[i] = Napi.from_napi_value(infos.env, infos.args[i].raw, arg.type.?);
                }

                if (@typeInfo(init_fn_info.@"fn".return_type.?) == .error_union) {
                    data.* = @call(.auto, init_fn, tuple_args) catch {
                        if (NapiError.last_error) |last_err| {
                            last_err.throwInto(napi_env.Env.from_raw(env));
                        }
                        GlobalAllocator.globalAllocator().destroy(data);
                        return null;
                    };
                } else {
                    data.* = @call(.auto, init_fn, tuple_args);
                }
            } else {
                data.* = std.mem.zeroes(T);
                if (comptime HasInit) {
                    inline for (fields, 0..) |field, i| {
                        @field(data.*, field.name) = Napi.from_napi_value(env, infos.args[i].raw, field.type);
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

        fn factory_method_callback(comptime factory_name: []const u8) type {
            return struct {
                fn call(env: napi.napi_env, callback_info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                    const infos = CallbackInfo.from_raw(env, callback_info);

                    const factory_fn = @field(T, factory_name);
                    const factory_fn_type = @TypeOf(factory_fn);
                    const factory_fn_info = @typeInfo(factory_fn_type);
                    const params = factory_fn_info.@"fn".params;

                    var instance_data: T = undefined;

                    if (params.len == 0) {
                        instance_data = factory_fn() catch return null;
                    } else {
                        var tuple_args: std.meta.ArgsTuple(factory_fn_type) = undefined;
                        inline for (params, 0..) |param, i| {
                            if (i < infos.args.len) {
                                tuple_args[i] = Napi.from_napi_value(infos.env, infos.args[i].raw, param.type.?);
                            }
                        }
                        if (@typeInfo(factory_fn_info.@"fn".return_type.?) == .error_union) {
                            instance_data = @call(.auto, factory_fn, tuple_args) catch return null;
                        } else {
                            instance_data = @call(.auto, factory_fn, tuple_args);
                        }
                    }

                    const constructor = class_constructors.get(class_name) orelse return null;
                    var js_instance: napi.napi_value = undefined;
                    _ = napi.napi_new_instance(env, constructor, infos.args_count, @ptrCast(infos.args_raw.ptr), &js_instance);

                    const heap_data = GlobalAllocator.globalAllocator().create(T) catch return null;
                    heap_data.* = instance_data;

                    var ref: napi.napi_ref = undefined;
                    const status = napi.napi_wrap(env, js_instance, heap_data, finalize_callback, null, &ref);
                    if (status != napi.napi_ok) {
                        GlobalAllocator.globalAllocator().destroy(heap_data);
                        return null;
                    }

                    var ref_count: u32 = undefined;
                    _ = napi.napi_reference_unref(env, ref, &ref_count);

                    return js_instance;
                }
            };
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
            comptime var property_count: usize = fields.len;

            inline for (decls) |decl| {
                const decl_type = @TypeOf(@field(T, decl.name));
                if (@typeInfo(decl_type) == .@"fn") {
                    const fn_name = decl.name;
                    if (comptime !std.mem.eql(u8, fn_name, "init") and
                        !std.mem.eql(u8, fn_name, "deinit"))
                    {
                        property_count += 1;
                    }
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
                const decl_type = @TypeOf(@field(T, decl.name));
                if (@typeInfo(decl_type) == .@"fn") {
                    const fn_name = decl.name;
                    if (comptime !std.mem.eql(u8, fn_name, "init") and
                        !std.mem.eql(u8, fn_name, "deinit"))
                    {
                        const method = @field(T, fn_name);
                        const method_info = @typeInfo(@TypeOf(method));
                        const params = method_info.@"fn".params;

                        const is_instance_method = params.len > 0 and (params[0].type.? == *T or params[0].type.? == T);

                        const return_type = method_info.@"fn".return_type.?;
                        const is_factory_method = blk: {
                            if ((return_type == T or return_type == *T)) break :blk true;
                            if (@typeInfo(return_type) == .error_union) {
                                if (@typeInfo(return_type).error_union.payload == T or @typeInfo(return_type).error_union.payload == *T) break :blk true;
                            }
                            break :blk false;
                        };

                        if (is_factory_method and !is_instance_method) {
                            const FactoryWrapper = factory_method_callback(fn_name);
                            properties[prop_idx] = napi.napi_property_descriptor{
                                .utf8name = @ptrCast(fn_name.ptr),
                                .name = null,
                                .method = FactoryWrapper.call,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = napi.napi_static,
                                .data = null,
                            };
                        } else {
                            const MethodWrapper = struct {
                                fn call(method_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                                    const cb_info = CallbackInfo.from_raw(method_env, info);
                                    var data: ?*anyopaque = null;
                                    _ = napi.napi_unwrap(method_env, cb_info.This(), &data);
                                    if (data == null) return null;

                                    var tuple_args: std.meta.ArgsTuple(@TypeOf(method)) = undefined;

                                    // inject instance
                                    if (is_instance_method) {
                                        if (method_info.@"fn".params[0].type.? != *T) {
                                            @compileError("Method " ++ fn_name ++ " must have a self parameter, which is a pointer to the class");
                                        }
                                        const instance: *T = @ptrCast(@alignCast(data.?));
                                        tuple_args[0] = instance;
                                    }

                                    const args_offset = if (is_instance_method) 1 else 0;
                                    // inject args
                                    inline for (method_info.@"fn".params[args_offset..], args_offset..) |param, i| {
                                        tuple_args[i] = Napi.from_napi_value(method_env, cb_info.args[i - args_offset].raw, param.type.?);
                                    }
                                    const result = @call(.auto, method, tuple_args);
                                    return Napi.to_napi_value(method_env, result, fn_name) catch null;
                                }
                            };

                            properties[prop_idx] = napi.napi_property_descriptor{
                                .utf8name = @ptrCast(fn_name.ptr),
                                .name = null,
                                .method = MethodWrapper.call,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = comptime if (is_instance_method) napi.napi_default else napi.napi_static,
                                .data = null,
                            };
                        }
                        prop_idx += 1;
                    }
                }
            }

            var constructor: napi.napi_value = undefined;
            _ = napi.napi_define_class(env, class_name.ptr, class_name.len, constructor_callback, null, prop_idx, &properties, &constructor);

            try class_constructors.put(class_name, constructor);
            return constructor;
        }

        fn define_custom_method(_: napi.napi_env, _: napi.napi_value) !void {}

        pub fn to_napi_value(env: napi_env.Env) !napi.napi_value {
            const constructor = try Self.define_class(env.raw);
            try Self.define_custom_method(env.raw, constructor);
            return constructor;
        }
    };
}

pub fn Class(comptime T: type) type {
    return ClassWrapper(T, true);
}

pub fn ClassWithoutInit(comptime T: type) type {
    return ClassWrapper(T, false);
}

pub fn isClass(T: anytype) bool {
    const type_name = @typeName(T);
    return std.mem.indexOf(u8, type_name, "ClassWrapper") != null;
}
