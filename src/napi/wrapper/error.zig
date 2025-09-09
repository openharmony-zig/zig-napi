const napi = @import("../../sys/api.zig");
const Status = @import("status.zig").Status;
const Env = @import("../env.zig").Env;

pub const Error = struct {
    status: Status,
    message: []const u8,

    env: ?napi.napi_env,
    raw: ?napi.napi_value,

    pub fn fromMessage(message: []const u8) Error {
        return Error{
            .env = null,
            .message = message,
            .status = Status.GenericFailure,
        };
    }

    pub fn fromStatus(status: Status) Error {
        return Error{
            .env = null,
            .message = "",
            .status = status,
        };
    }
};
