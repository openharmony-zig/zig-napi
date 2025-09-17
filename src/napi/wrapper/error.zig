const std = @import("std");
const napi = @import("napi-sys");
const Env = @import("../env.zig").Env;
const String = @import("../value/string.zig").String;

pub const Status = @import("status.zig").Status;

// Save the last error to the threadlocal variable and throw it when the error is not null
pub threadlocal var last_error: ?Error = null;

pub const ErrorStatus = error{
    InvalidArg,
    ObjectExpected,
    StringExpected,
    NameExpected,
    FunctionExpected,
    NumberExpected,
    BooleanExpected,
    ArrayExpected,
    GenericFailure,
    PendingException,
    Cancelled,
    EscapeCalledTwice,
    HandleScopeMismatch,
    CallbackScopeMismatch,
    /// ThreadSafeFunction queue is full
    QueueFull,
    /// ThreadSafeFunction closed
    Closing,
    BigintExpected,
    DateExpected,
    ArrayBufferExpected,
    DetachableArraybufferExpected,
    WouldDeadlock,
    NoExternalBuffersAllowed,
    Unknown,
    CustomStatus,
};

fn toError(status: Status) anyerror {
    return switch (status) {
        .InvalidArg => error.InvalidArg,
        .ObjectExpected => error.ObjectExpected,
        .StringExpected => error.StringExpected,
        .NameExpected => error.NameExpected,
        .FunctionExpected => error.FunctionExpected,
        .NumberExpected => error.NumberExpected,
        .BooleanExpected => error.BooleanExpected,
        .ArrayExpected => error.ArrayExpected,
        .GenericFailure => error.GenericFailure,
        .PendingException => error.PendingException,
        .Cancelled => error.Cancelled,
        .EscapeCalledTwice => error.EscapeCalledTwice,
        .HandleScopeMismatch => error.HandleScopeMismatch,
        .CallbackScopeMismatch => error.CallbackScopeMismatch,
        .QueueFull => error.QueueFull,
        .Closing => error.Closing,
        .BigintExpected => error.BigintExpected,
        .DateExpected => error.DateExpected,
        .ArrayBufferExpected => error.ArrayBufferExpected,
        .DetachableArraybufferExpected => error.DetachableArraybufferExpected,
        .WouldDeadlock => error.WouldDeadlock,
        .NoExternalBuffersAllowed => error.NoExternalBuffersAllowed,
        .Unknown => error.Unknown,
        else => error.CustomStatus,
    };
}

fn napiError(comptime T: type) type {
    return struct {
        status: Status,
        message: []const u8,
        mode: T,

        const Self = @This();

        pub fn to_napi_error(self: Self, env: Env) napi.napi_value {
            var e: napi.napi_value = undefined;
            const code: napi.napi_value = String.New(env, self.status.ToString()).raw;
            const message: napi.napi_value = String.New(env, self.message).raw;
            const create_status = switch (T) {
                JsErrorType => napi.napi_create_error(env.raw, code, message, &e),
                JsTypeErrorType => napi.napi_create_type_error(env.raw, code, message, &e),
                JsRangeErrorType => napi.napi_create_range_error(env.raw, code, message, &e),
                else => unreachable,
            };
            std.debug.assert(create_status == napi.napi_ok);
            return e;
        }

        pub fn fromMessage(message: []const u8) Self {
            return Self{
                .message = message,
                .status = Status.GenericFailure,
                .mode = T{},
            };
        }

        pub fn fromStatus(status: Status) Self {
            return Self{
                .status = status,
                .message = "",
                .mode = T{},
            };
        }

        pub fn throwInto(self: Self, env: Env) void {
            var e: napi.napi_value = undefined;
            const code: napi.napi_value = String.New(env, self.status.ToString()).raw;
            const message: napi.napi_value = String.New(env, self.message).raw;

            const create_status = switch (T) {
                JsErrorType => napi.napi_create_error(env.raw, code, message, &e),
                JsTypeErrorType => napi.napi_create_type_error(env.raw, code, message, &e),
                JsRangeErrorType => napi.napi_create_range_error(env.raw, code, message, &e),
                else => unreachable,
            };
            std.debug.assert(create_status == napi.napi_ok);

            const throw_status = napi.napi_throw(env.raw, e);
            std.debug.assert(throw_status == napi.napi_ok);
        }
    };
}

const JsErrorType = struct {};
const JsTypeErrorType = struct {};
const JsRangeErrorType = struct {};

pub const JsError = napiError(JsErrorType);
pub const JsTypeError = napiError(JsTypeErrorType);
pub const JsRangeError = napiError(JsRangeErrorType);

pub fn checkNapiStatus(env: napi.napi_env, err: anytype) napi.napi_value {
    const err_type = @TypeOf(err);
    const infos = @typeInfo(err_type);

    const inner_env = Env.from_raw(env);
    var result: napi.napi_value = undefined;
    const status = napi.napi_get_undefined(env, &result);
    std.debug.assert(status == napi.napi_ok);

    switch (err_type) {
        Status => {
            const js_error = Error{ .JsError = JsError.fromStatus(err) };
            js_error.throwInto(inner_env);
        },
        else => {
            switch (infos) {
                .@"struct" => {
                    const js_error = Error{ .JsError = JsError.fromStatus(err.status) };
                    js_error.throwInto(inner_env);
                },
                else => {
                    @compileError("Unsupported type: " ++ @typeName(err_type));
                },
            }
        },
    }
    return result;
}

pub const Error = union(enum) {
    JsError: JsError,
    JsTypeError: JsTypeError,
    JsRangeError: JsRangeError,

    pub fn to_napi_error(self: Error, env: Env) napi.napi_value {
        return switch (self) {
            .JsError => self.JsError.to_napi_error(env),
            .JsTypeError => self.JsTypeError.to_napi_error(env),
            .JsRangeError => self.JsRangeError.to_napi_error(env),
        };
    }

    pub fn fromReason(reason: []const u8) anyerror {
        last_error = Error{ .JsError = JsError.fromMessage(reason) };
        return error.GenericFailure;
    }

    pub fn fromStatus(status: Status) anyerror {
        last_error = Error{ .JsError = JsError.fromStatus(status) };
        return toError(status);
    }

    pub fn typeError(message: []const u8) anyerror {
        last_error = Error{ .JsTypeError = JsTypeError.fromMessage(message) };
        return error.GenericFailure;
    }

    pub fn rangeError(message: []const u8) anyerror {
        last_error = Error{ .JsRangeError = JsRangeError.fromMessage(message) };
        return error.GenericFailure;
    }

    pub fn throwInto(self: Error, env: Env) void {
        switch (self) {
            .JsError => self.JsError.throwInto(env),
            .JsTypeError => self.JsTypeError.throwInto(env),
            .JsRangeError => self.JsRangeError.throwInto(env),
        }
    }
};
