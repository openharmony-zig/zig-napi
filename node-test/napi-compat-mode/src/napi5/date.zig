const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

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

pub fn createDate(env: napi.Env, value: f64) !c.napi_value {
    var raw: c.napi_value = undefined;
    const status = c.napi_create_date(env.raw, value, &raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return raw;
}

pub fn getDateValue(value: napi.Object) !f64 {
    return try value.dateValue();
}
