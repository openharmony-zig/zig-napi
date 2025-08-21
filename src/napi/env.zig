const napi = @import("../sys/api.zig").napi;

pub const Env = struct {
    raw: napi.napi_env,

    pub fn from_raw(raw: napi.napi_env) Env {
        return Env{
            .raw = raw,
        };
    }
};
