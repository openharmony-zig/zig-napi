const std = @import("std");
const napi = @import("napi");

const FullField = struct {
    name: []u8,
    age: f64,
    is_student: bool,
};

pub fn get_object(config: FullField) FullField {
    return config;
}

const OptionalField = struct {
    name: []u8,
    age: ?f64,
    is_student: ?bool,
};

pub fn get_object_optional(config: OptionalField) OptionalField {
    const newConfig = OptionalField{
        .name = config.name,
        .age = config.age orelse 18,
        .is_student = config.is_student orelse true,
    };
    return newConfig;
}

pub fn get_optional_object_and_return_optional(config: OptionalField) OptionalField {
    return config;
}

const NullableField = struct {
    name: ?[]u8,
};

pub fn get_nullable_object(config: NullableField) NullableField {
    return config;
}

pub fn return_nullable() NullableField {
    return NullableField{ .name = null };
}

pub fn raw_object_read(config: napi.Object, key: napi.String) i32 {
    const key_bytes = key.copyUtf8();
    defer napi.globalAllocator().free(key_bytes);
    return config.Get(key_bytes, i32);
}

pub fn raw_object_create(env: napi.Env, key: napi.String, value: i32) !napi.Object {
    const key_bytes = key.copyUtf8();
    defer napi.globalAllocator().free(key_bytes);

    var object = try napi.Object.Create(env);
    try object.Set(key_bytes, value);
    return object;
}
