const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const CallbackInfo = @import("./callback_info.zig").CallbackInfo;
const Function = @import("../value/function.zig").Function;
const napi_env = @import("../env.zig");
const helper = @import("../util/helper.zig");
const allocator = @import("../util/allocator.zig").global_allocator;

var class_constructor_ref: std.AutoHashMap([]const u8, napi.napi_ref) = std.AutoHashMap([]const u8, napi.napi_ref).init(allocator);

pub fn ClassInstance(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Class must be a struct type");
    }

    if (type_info.@"struct".is_tuple) {
        @compileError("Class must be a named struct type, don't support tuple type");
    }

    const class_name = @typeName(T);
    const class_fields = type_info.@"struct".fields;
    const class_methods = type_info.@"struct".decls;

    const constructor = blk: for (class_methods) |method| {
        if (std.mem.eql(u8, method.name, "Constructor")) {
            break :blk method.value;
        }
        break :blk null;
    } else {
        @compileError("Class must have a public constructor");
    };

    const factory = blk: for (class_methods) |method| {
        if (std.mem.eql(u8, method.name, "Factory")) {
            break :blk method.value;
        }
        break :blk null;
    } else {
        @compileError("Class must have a public factory");
    };

    return struct {
        name: []const u8,
        env: napi.napi_env,
        raw: napi.napi_value,
        ref: napi.napi_ref,
        value: T,

        const Self = @This();

        pub fn New(env: napi.napi_env, callback_info: napi.napi_callback_info) *Self {
            const self = allocator.create(Self) catch @panic("OOM");

            const data = allocator.create(T) catch @panic("OOM");
            self.value = data.*;

            var new_target: napi.napi_value = undefined;
            _ = napi.napi_get_new_target(env, callback_info, &new_target);

            if (new_target == null) {
                const constructor_ref = class_constructor_ref.get(@typeName(T));
                if (constructor_ref == null) {
                    @panic("Class constructor reference not found");
                }

                _ = napi.napi_get_reference_value(env, constructor_ref.?, &self.raw);
                _ = napi.napi_wrap(env, self.raw, data, null, null, &self.ref);

                return self;
            } else {
                const this = infos.This();

                _ = napi.napi_wrap(env, this, data, null, null, &self.ref);

                // align with node.js behavior
                var ref_count: u32 = undefined;
                napi.napi_reference_unref(env, self.ref, &ref_count);

                return self;
            }
        }
    };
}

pub fn Class(env: napi_env.Env, comptime T: type) ClassInstance(@TypeOf(T)) {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Class must be a struct type");
    }

    if (type_info.@"struct".is_tuple) {
        @compileError("Class must be a named struct type, don't support tuple type");
    }

    const class_name = @typeName(T);
    const class_fields = type_info.@"struct".fields;
    const class_methods = type_info.@"struct".decls;

    comptime var properties: [class_fields.len + class_methods.len]napi.napi_property_descriptor = undefined;

    comptime var property_count: usize = 0;

    inline for (class_fields) |field| {
        const Property = struct {
            pub fn setter(setter_env: napi.napi_env, setter_info: napi.napi_callback_info) napi.napi_value {}

            pub fn getter(getter_env: napi.napi_env, getter_info: napi.napi_callback_info) napi.napi_value {}
        };

        properties[property_count] = napi.napi_property_descriptor{
            .utf8name = @ptrCast(field.name),
            .utf8name_length = field.name.len,
            .getter = &Property.getter,
            .setter = &Property.setter,
        };
        property_count += 1;
    }

    inline for (class_methods) |method| {
        const method_infos = @typeInfo(method);

        if (method_infos != .@"fn") {
            @compileError("Method must be a function type");
        }

        const params = method_infos.@"fn".params;
        const hasSelf = comptime params.len > 0 and params[0].type.? == T;

        if (std.mem.startsWith(u8, method.name, "Getter")) {
            const name = method.name[6..];
            const Getter = struct {
                pub fn getter(getter_env: napi.napi_env, getter_info: napi.napi_callback_info) napi.napi_value {}
            };
            properties[property_count] = napi.napi_property_descriptor{
                .utf8name = @ptrCast(name),
                .utf8name_length = name.len,
                .getter = &Getter.getter,
                .setter = null,
            };
        }
        if (std.mem.startsWith(u8, method.name, "Setter")) {
            const name = method.name[6..];
            const Setter = struct {
                pub fn setter(setter_env: napi.napi_env, setter_info: napi.napi_callback_info) napi.napi_value {}
            };
            properties[property_count] = napi.napi_property_descriptor{
                .utf8name = @ptrCast(name),
                .utf8name_length = name.len,
                .getter = null,
                .setter = &Setter.setter,
            };
        }

        const Method = struct {
            pub fn call(method_env: napi.napi_env, method_info: napi.napi_callback_info) napi.napi_value {}
        };

        properties[property_count] = napi.napi_property_descriptor{
            .utf8name = @ptrCast(method.name),
            .utf8name_length = method.name.len,
            .method = &Method.call,
            .getter = null,
            .setter = null,
            .attributes = if (hasSelf) napi.napi_default_method else napi.napi_static,
        };
        property_count += 1;
    }

    const instance = ClassInstance(@TypeOf(T));

    var con: napi.napi_value = undefined;
    _ = napi.napi_define_class(env.raw, @ptrCast(class_name), class_name.len, instance.New, null, property_count, &properties, &con);

    var ref: napi.napi_ref = undefined;
    _ = napi.napi_create_reference(env.raw, con, 1, &ref);

    class_constructor_ref.put(class_name, ref);

    return instance;
}
