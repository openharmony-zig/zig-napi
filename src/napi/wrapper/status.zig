const napi = @import("../../sys/api.zig");

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
};
