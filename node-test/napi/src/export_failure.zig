const napi = @import("napi");
const api = napi.napi_sys.napi_sys;

const FailingExport = struct {
    pub const napi_custom = true;

    pub fn to_napi_value(_: @This(), _: api.napi_env) !api.napi_value {
        return error.OutOfMemory;
    }
};

pub const value = FailingExport{};

comptime {
    napi.NODE_API_MODULE("export_failure", @This());
}
