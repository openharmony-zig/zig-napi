const std = @import("std");
const napi = @import("napi");
const ArrayList = std.ArrayList;

const Person = struct {
    name: []u8,
    age: f64,
    is_student: bool,
};

const NamedTuple = struct { f32, bool, []u8 };

const NumberOrText = union(enum) {
    number: f64,
    text: []const u8,
};

const OptionalPerson = struct {
    name: []u8,
    age: ?f64,
    is_student: ?bool,
};

const NestedPayload = struct {
    title: []u8,
    values: []f32,
    tuple: NamedTuple,
    maybe: ?[]u8,
};

const FnArgs = struct { i32, i32 };
const FnReturn = i32;

pub fn hello(env: napi.Env, name: []u8) napi.String {
    const allocator = std.heap.page_allocator;
    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);
    return napi.String.New(env, message);
}

pub fn get_object(config: Person) Person {
    return config;
}

pub fn get_optional_object(config: OptionalPerson) OptionalPerson {
    return .{
        .name = config.name,
        .age = config.age orelse 18,
        .is_student = config.is_student orelse true,
    };
}

pub fn nullable_name_is_null(name: ?[]u8) bool {
    return name == null;
}

pub fn get_named_array(array: NamedTuple) NamedTuple {
    return array;
}

pub fn array_sum(values: []f32) f64 {
    var sum: f64 = 0;
    for (values) |value| {
        sum += value;
    }
    return sum;
}

pub fn arraylist_sum(values: ArrayList(f32)) f64 {
    var sum: f64 = 0;
    for (values.items) |value| {
        sum += value;
    }
    return sum;
}

pub fn nested_summary(payload: NestedPayload) usize {
    return payload.title.len + payload.values.len + payload.tuple[2].len + if (payload.maybe) |text| text.len else 0;
}

pub fn union_kind(value: NumberOrText) []const u8 {
    return switch (value) {
        .number => "number",
        .text => "text",
    };
}

fn basic_function(left: i32, right: i32) i32 {
    return left + right;
}

pub fn create_function(env: napi.Env) !napi.Function(FnArgs, FnReturn) {
    return try napi.Function(FnArgs, FnReturn).New(env, "memory_basic_function", basic_function);
}

pub fn call_function(cb: napi.Function(FnArgs, FnReturn)) !i32 {
    return try cb.Call(.{ 20, 22 });
}

pub fn call_function_with_reference(env: napi.Env, cb: napi.Function(FnArgs, FnReturn)) !i32 {
    var reference = try cb.CreateRef();
    defer reference.Unref(env) catch @panic("Failed to unref function reference");

    const function = try reference.GetValue(env);
    return try function.Call(.{ 19, 23 });
}

pub fn function_reference_ref_count(env: napi.Env, cb: napi.Function(FnArgs, FnReturn)) !u32 {
    var reference = try cb.CreateRef();
    const count = try reference.Ref(env);
    try reference.Unref(env);
    return count;
}

pub fn create_bigint_value(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, 9007199254740993));
}

pub fn create_small_bigint_value(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, 42));
}

pub fn bigint_to_i64(value: napi.BigInt) i64 {
    return napi.BigInt.from_napi_value(value.env, value.raw, i64);
}

pub fn manual_resolved_promise(env: napi.Env) !napi.Promise {
    var promise = napi.Promise.New(env);
    try promise.Resolve(@as(i32, 42));
    return promise;
}
