const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

const DateCandidate = union(enum) {
    number: i32,
    object: napi.Object,
};

pub fn isDate(value: DateCandidate) bool {
    return switch (value) {
        .number => false,
        .object => |object| blk: {
            var result = false;
            _ = c.napi_is_date(object.env, object.raw, &result);
            break :blk result;
        },
    };
}

pub fn createDate(env: napi.Env, value: f64) !c.napi_value {
    var raw: c.napi_value = undefined;
    const status = c.napi_create_date(env.raw, value, &raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return raw;
}

pub fn getDateValue(value: napi.Object) !f64 {
    var result: f64 = 0;
    const status = c.napi_get_date_value(value.env, value.raw, &result);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return result;
}
