const napi = @import("napi");

const DateCandidate = union(enum) {
    number: i32,
    object: napi.Object,
};

pub fn isDate(value: DateCandidate) !bool {
    return switch (value) {
        .number => false,
        .object => |object| try object.isDate(),
    };
}

pub fn createDate(env: napi.Env, value: f64) !napi.Object {
    return try env.createDate(value);
}

pub fn getDateValue(value: napi.Object) !f64 {
    return try value.dateValue();
}
