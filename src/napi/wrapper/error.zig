const napi = @import("napi-sys");
const Status = @import("status.zig").Status;
const Env = @import("../env.zig").Env;

pub const JsError = struct {
    status: Status,
    message: []const u8,

    env: ?napi.napi_env,
    raw: ?napi.napi_value,

    pub fn fromMessage(message: []const u8) JsError {
        return JsError{
            .env = null,
            .message = message,
            .status = Status.GenericFailure,
        };
    }

    pub fn fromStatus(status: Status) JsError {
        return JsError{
            .env = null,
            .message = "",
            .status = status,
        };
    }
};

pub const Error = enum {
    JsError,
    JsExceptionError,
    JsSyntaxError,
};
