const napi = @import("napi-sys").napi_sys;
const build_options = @import("build_options");

// Copy from napi-rs
pub const Status = enum(u32) {
    Ok = 0,
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
    CannotRunJs,
    RuntimeSpecific24,
    Unknown = 1024, // unknown status. for example, using napi3 module in napi7 Node.js, and generate an invalid napi3 status

    pub fn from_raw(raw: napi.napi_status) Status {
        const status_code: u32 = @intCast(raw);
        return switch (status_code) {
            0 => .Ok,
            1 => .InvalidArg,
            2 => .ObjectExpected,
            3 => .StringExpected,
            4 => .NameExpected,
            5 => .FunctionExpected,
            6 => .NumberExpected,
            7 => .BooleanExpected,
            8 => .ArrayExpected,
            9 => .GenericFailure,
            10 => .PendingException,
            11 => .Cancelled,
            12 => .EscapeCalledTwice,
            13 => .HandleScopeMismatch,
            14 => .CallbackScopeMismatch,
            15 => .QueueFull,
            16 => .Closing,
            17 => .BigintExpected,
            18 => .DateExpected,
            19 => .ArrayBufferExpected,
            20 => .DetachableArraybufferExpected,
            21 => .WouldDeadlock,
            22 => .NoExternalBuffersAllowed,
            23 => .CannotRunJs,
            24 => .RuntimeSpecific24,
            else => .Unknown,
        };
    }

    pub fn New(status: anytype) Status {
        return Status.from_raw(status);
    }

    pub fn isOk(self: Status) bool {
        return self == .Ok;
    }

    pub fn code(self: Status) u32 {
        return @intFromEnum(self);
    }

    pub fn toString(self: Status) []const u8 {
        return self.ToString();
    }

    pub fn ToString(self: Status) []const u8 {
        return switch (self) {
            .Ok => "Ok",
            .InvalidArg => "InvalidArg",
            .ObjectExpected => "ObjectExpected",
            .StringExpected => "StringExpected",
            .NameExpected => "NameExpected",
            .FunctionExpected => "FunctionExpected",
            .NumberExpected => "NumberExpected",
            .BooleanExpected => "BooleanExpected",
            .ArrayExpected => "ArrayExpected",
            .GenericFailure => "GenericFailure",
            .PendingException => "PendingException",
            .Cancelled => "Cancelled",
            .EscapeCalledTwice => "EscapeCalledTwice",
            .HandleScopeMismatch => "HandleScopeMismatch",
            .CallbackScopeMismatch => "CallbackScopeMismatch",
            .QueueFull => "QueueFull",
            .Closing => "Closing",
            .BigintExpected => "BigintExpected",
            .DateExpected => "DateExpected",
            .ArrayBufferExpected => "ArrayBufferExpected",
            .DetachableArraybufferExpected => "DetachableArraybufferExpected",
            .WouldDeadlock => "WouldDeadlock",
            .NoExternalBuffersAllowed => if (build_options.node_addon) "NoExternalBuffersAllowed" else "CreateArkRuntimeTooManyEnvs",
            .CannotRunJs => if (build_options.node_addon) "CannotRunJs" else "CreateArkRuntimeOnlyOneEnvPerThread",
            .RuntimeSpecific24 => if (build_options.node_addon) "RuntimeSpecific24" else "DestroyArkRuntimeEnvNotExist",
            else => "Unknown",
        };
    }
};
