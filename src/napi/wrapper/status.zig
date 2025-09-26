const napi = @import("napi-sys").napi_sys;

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
    Unknown = 1024, // unknown status. for example, using napi3 module in napi7 Node.js, and generate an invalid napi3 status

    pub fn from_raw(raw: napi.napi_status) Status {
        return @as(Status, @enumFromInt(@as(u32, raw)));
    }

    pub fn New(status: anytype) Status {
        return @as(Status, @enumFromInt(@as(u32, status)));
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
            .NoExternalBuffersAllowed => "NoExternalBuffersAllowed",
            else => "Unknown",
        };
    }
};
