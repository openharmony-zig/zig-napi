const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const String = @import("../value/string.zig").String;

pub const Status = @import("status.zig").Status;

// Save the last error to the threadlocal variable and throw it when the error is not null
pub threadlocal var last_error: ?Error = null;
/// Status of the N-API call that produced `last_error`.
/// `PendingException` is used as a marker for "a JavaScript exception is already
/// pending in the environment and must be propagated as is".
pub threadlocal var last_error_status: ?Status = null;

pub fn clearLastError() void {
    last_error = null;
    last_error_status = null;
}

/// Snapshot of the threadlocal error state, used to save/restore error frames
/// around nested entries into JavaScript (callbacks, getters, module init).
///
/// A frame also *pins* the rotating message slot its error points into, so
/// nested reentries that format more messages cannot overwrite the text of an
/// error that is still waiting to be thrown by an outer frame.
pub const ErrorFrame = struct {
    error_value: ?Error,
    status: ?Status,
    pinned_slot: ?usize,

    pub fn save() ErrorFrame {
        return pinFrame(.{
            .error_value = last_error,
            .status = last_error_status,
            .pinned_slot = null,
        });
    }

    /// Restore this frame and release its message pin.
    ///
    /// Frames must be restored in reverse order of `save` (the usual
    /// `defer frame.restore();` pattern).
    pub fn restore(self: ErrorFrame) void {
        unpinFrame(self);
        last_error = self.error_value;
        last_error_status = self.status;
    }
};

/// Copy of `frame` whose message slot is pinned (reference counted) for as long
/// as the frame is alive.
fn pinFrame(frame: ErrorFrame) ErrorFrame {
    var result = frame;
    const message = if (frame.error_value) |err| messageOf(err) else "";
    if (message.len == 0) return result;
    if (messageSlotOf(message)) |slot| {
        message_slot_pins[slot] += 1;
        result.pinned_slot = slot;
    }
    return result;
}

fn unpinFrame(frame: ErrorFrame) void {
    if (frame.pinned_slot) |slot| {
        if (message_slot_pins[slot] > 0) message_slot_pins[slot] -= 1;
    }
}

fn messageOf(err: Error) []const u8 {
    return switch (err) {
        .JsError => |inner| inner.message,
        .JsTypeError => |inner| inner.message,
        .JsRangeError => |inner| inner.message,
    };
}

/// Mark that the environment already holds a pending JavaScript exception.
/// The conversion layer must not create a new error in that case, otherwise the
/// original exception object (for example one thrown by a getter) is replaced.
pub fn setPendingException() void {
    last_error = null;
    last_error_status = .PendingException;
}

pub fn hasPendingException() bool {
    return last_error == null and last_error_status != null and last_error_status.? == .PendingException;
}

/// Message storage for dynamically formatted error messages.
///
/// `Error` stores a `[]const u8`, so formatted messages need stable storage for
/// the lifetime of the error state. A rotating set of threadlocal slots keeps
/// nested conversions from overwriting each other; slots referenced by a live
/// `ErrorFrame` are pinned and skipped, so an error saved by an outer frame
/// keeps its text across any number of nested reentries.
const message_slot_count = 8;
const message_slot_len = 256;
threadlocal var message_slots: [message_slot_count][message_slot_len]u8 = undefined;
threadlocal var message_slot_index: usize = 0;
threadlocal var message_slot_pins: [message_slot_count]u16 = .{0} ** message_slot_count;

pub fn formatMessage(comptime fmt: []const u8, args: anytype) []const u8 {
    const slot = &message_slots[takeMessageSlot()];
    return std.fmt.bufPrint(slot, fmt, args) catch fmt;
}

/// Which ring slot (if any) stores `message`.
fn messageSlotOf(message: []const u8) ?usize {
    const pointer = @intFromPtr(message.ptr);
    for (&message_slots, 0..) |*slot, index| {
        const base = @intFromPtr(slot);
        if (pointer >= base and pointer < base + message_slot_len) return index;
    }
    return null;
}

/// Next slot that is not pinned by a live frame. When every slot is pinned the
/// oldest one is reused, which can only happen with more simultaneously saved
/// error frames than slots.
fn takeMessageSlot() usize {
    var candidate: usize = 0;
    while (candidate < message_slot_count) : (candidate += 1) {
        const slot = (message_slot_index + candidate) % message_slot_count;
        if (message_slot_pins[slot] == 0) {
            message_slot_index = (slot + 1) % message_slot_count;
            return slot;
        }
    }

    const slot = message_slot_index;
    message_slot_index = (slot + 1) % message_slot_count;
    return slot;
}

/// Record a failed N-API call. A pending JavaScript exception is preserved
/// instead of being replaced by a freshly created error.
pub fn failWithStatus(status: Status) anyerror {
    if (status == .PendingException) {
        setPendingException();
        return error.PendingException;
    }
    last_error = Error{ .JsError = JsError.fromStatus(status) };
    last_error_status = status;
    return toError(status);
}

pub fn failStatus(status: anytype) anyerror {
    return failWithStatus(Status.New(status));
}

pub fn failTypeError(comptime fmt: []const u8, args: anytype) anyerror {
    last_error = Error{ .JsTypeError = JsTypeError.fromMessage(formatMessage(fmt, args)) };
    last_error_status = .GenericFailure;
    return error.GenericFailure;
}

pub fn failRangeError(comptime fmt: []const u8, args: anytype) anyerror {
    last_error = Error{ .JsRangeError = JsRangeError.fromMessage(formatMessage(fmt, args)) };
    last_error_status = .GenericFailure;
    return error.GenericFailure;
}

pub fn failError(comptime fmt: []const u8, args: anytype) anyerror {
    last_error = Error{ .JsError = JsError.fromMessage(formatMessage(fmt, args)) };
    last_error_status = .GenericFailure;
    return error.GenericFailure;
}

/// Throw the recorded error into the environment unless a JavaScript exception
/// is already pending, in which case the pending exception is left untouched.
pub fn throwCurrent(env: Env) void {
    if (last_error) |err| {
        clearLastError();
        err.throwInto(env);
    }
}

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
    CannotRunJs,
    RuntimeSpecific24,
    Unknown,
};

pub fn toError(status: Status) anyerror {
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
        .CannotRunJs => error.CannotRunJs,
        .RuntimeSpecific24 => error.RuntimeSpecific24,
        else => error.Unknown,
    };
}

fn napiError(comptime T: type) type {
    return struct {
        status: ?Status,
        /// Borrowed message. Static literals are never freed; dynamically
        /// formatted messages live in `message()` slots.
        message: []const u8,
        mode: T,
        custom_status: ?[]const u8,

        const Self = @This();

        /// Marks the error payload as borrowed data for ownership handling.
        pub const is_napi_error = true;

        pub fn to_napi_error(self: Self, env: Env) napi.napi_value {
            var e: napi.napi_value = undefined;
            const status_str = if (self.custom_status) |custom_status| custom_status else self.status.?.ToString();
            const code: napi.napi_value = String.New(env, status_str).raw;
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
                .custom_status = null,
            };
        }

        pub fn fromStatus(status: anytype) Self {
            const type_info = @TypeOf(status);
            switch (type_info) {
                Status => {
                    return Self{
                        .status = status,
                        .message = "",
                        .mode = T{},
                        .custom_status = null,
                    };
                },
                else => {
                    return Self{
                        .status = null,
                        .message = "",
                        .mode = T{},
                        .custom_status = status,
                    };
                },
            }
        }

        pub fn throwInto(self: Self, env: Env) void {
            var e: napi.napi_value = undefined;
            const status_str = if (self.custom_status) |custom_status| custom_status else self.status.?.ToString();
            const code: napi.napi_value = String.New(env, status_str).raw;
            const message: napi.napi_value = String.New(env, self.message).raw;

            const create_status = switch (T) {
                JsErrorType => napi.napi_create_error(env.raw, code, message, &e),
                JsTypeErrorType => napi.napi_create_type_error(env.raw, code, message, &e),
                JsRangeErrorType => napi.napi_create_range_error(env.raw, code, message, &e),
                else => unreachable,
            };
            std.debug.assert(create_status == napi.napi_ok);

            const throw_status = napi.napi_throw(env.raw, e);
            // `napi_throw` reports `napi_pending_exception` when JavaScript already
            // holds one. The existing exception wins; overwriting it would replace
            // the original error object (for example the one thrown by a getter).
            std.debug.assert(throw_status == napi.napi_ok or throw_status == napi.napi_pending_exception);
        }
    };
}

const JsErrorType = struct {};
const JsTypeErrorType = struct {};
const JsRangeErrorType = struct {};

pub const JsError = napiError(JsErrorType);
pub const JsTypeError = napiError(JsTypeErrorType);
pub const JsRangeError = napiError(JsRangeErrorType);

/// Check the napi status and throw the error into the environment
pub fn checkNapiStatus(env: napi.napi_env, err: anytype) napi.napi_value {
    const err_type = @TypeOf(err);

    const inner_env = Env.from_raw(env);
    var result: napi.napi_value = undefined;
    const status = napi.napi_get_undefined(env, &result);
    std.debug.assert(status == napi.napi_ok);

    switch (err_type) {
        Status => {
            const js_error = Error{ .JsError = JsError.fromStatus(err) };
            js_error.throwInto(inner_env);
        },
        else => @compileError("Unsupported type: " ++ @typeName(err_type)),
    }
    return result;
}

/// Error union for the napi error
pub const Error = union(enum) {
    JsError: JsError,
    JsTypeError: JsTypeError,
    JsRangeError: JsRangeError,

    /// Error payloads only borrow their message strings, so ownership handling
    /// must never free them.
    pub const is_napi_error = true;

    pub fn to_napi_error(self: Error, env: Env) napi.napi_value {
        return switch (self) {
            .JsError => self.JsError.to_napi_error(env),
            .JsTypeError => self.JsTypeError.to_napi_error(env),
            .JsRangeError => self.JsRangeError.to_napi_error(env),
        };
    }

    pub fn withReason(reason: []const u8) Error {
        return Error{ .JsError = JsError.fromMessage(reason) };
    }

    pub fn withStatus(status: anytype) Error {
        const type_info = @TypeOf(status);
        if (type_info != Status and type_info != []const u8) {
            @compileError("Error Status must be Status or []const u8, Unsupported type: " ++ @typeName(type_info));
        }

        return Error{ .JsError = JsError.fromStatus(status) };
    }

    pub fn withCodeAndMessage(code: []const u8, message: []const u8) Error {
        return Error{
            .JsError = JsError{
                .status = null,
                .message = message,
                .mode = JsErrorType{},
                .custom_status = code,
            },
        };
    }

    pub fn fromAnyError(err: anyerror) Error {
        return mapAnyError(err);
    }

    pub fn withTypeError(reason: []const u8) Error {
        return Error{ .JsTypeError = JsTypeError.fromMessage(reason) };
    }

    pub fn withRangeError(reason: []const u8) Error {
        return Error{ .JsRangeError = JsRangeError.fromMessage(reason) };
    }

    /// Create a new error from the reason and throw it
    pub fn fromReason(reason: []const u8) anyerror {
        last_error = Error{ .JsError = JsError.fromMessage(reason) };
        return error.GenericFailure;
    }

    /// Create a new error from the status and throw it
    pub fn fromStatus(status: anytype) anyerror {
        const type_info = @TypeOf(status);
        if (type_info != Status and type_info != []const u8) {
            @compileError("Error Status must be Status or []const u8, Unsupported type: " ++ @typeName(type_info));
        }

        last_error = Error{ .JsError = JsError.fromStatus(status) };
        return error.GenericFailure;
    }

    /// Create a new TypeError from the reason and throw it
    pub fn typeError(message: []const u8) anyerror {
        last_error = Error{ .JsTypeError = JsTypeError.fromMessage(message) };
        return error.GenericFailure;
    }

    /// Create a new RangeError from the reason and throw it
    pub fn rangeError(message: []const u8) anyerror {
        last_error = Error{ .JsRangeError = JsRangeError.fromMessage(message) };
        return error.GenericFailure;
    }

    /// Throw the error into the environment
    pub fn throwInto(self: Error, env: Env) void {
        switch (self) {
            .JsError => self.JsError.throwInto(env),
            .JsTypeError => self.JsTypeError.throwInto(env),
            .JsRangeError => self.JsRangeError.throwInto(env),
        }
    }
};

pub fn mapAnyError(err: anyerror) Error {
    if (last_error) |last_err| {
        clearLastError();
        return last_err;
    }

    return switch (err) {
        error.Canceled, error.Cancelled => Error.withReason("AbortError"),
        error.Closing => Error.withStatus(@as([]const u8, "Closing")),
        else => |actual_err| blk: {
            const name = @errorName(actual_err);
            break :blk Error.withCodeAndMessage(name[0..name.len], name[0..name.len]);
        },
    };
}

pub fn throwAnyErrorInto(err: anyerror, env: Env) void {
    mapAnyError(err).throwInto(env);
}

pub fn Result(comptime T: type) type {
    return union(enum) {
        pub const is_napi_result = true;
        pub const payload_type = T;

        ok: T,
        err: Error,

        const Self = @This();

        pub fn Ok(value: T) Self {
            return .{ .ok = value };
        }

        pub fn Err(err: Error) Self {
            return .{ .err = err };
        }
    };
}

pub fn isResult(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"union" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_result") and T.is_napi_result;
}

pub fn resultPayload(comptime T: type) type {
    if (!isResult(T)) {
        @compileError("Type is not napi.Result: " ++ @typeName(T));
    }
    return T.payload_type;
}

// ---------------------------------------------------------------------- tests

test "error frames keep the outer message across nested reentry" {
    clearLastError();
    last_error = Error{ .JsTypeError = JsTypeError.fromMessage(formatMessage("outer failure {d}", .{7})) };
    const expected = messageOf(last_error.?);

    const outer = ErrorFrame.save();

    // Nested JavaScript reentry formats far more messages than the ring holds.
    var i: usize = 0;
    while (i < message_slot_count * 4) : (i += 1) {
        last_error = Error{ .JsRangeError = JsRangeError.fromMessage(formatMessage("nested {d}", .{i})) };
    }

    outer.restore();

    try std.testing.expect(last_error != null);
    try std.testing.expectEqualStrings("outer failure 7", messageOf(last_error.?));
    try std.testing.expect(expected.len != 0);
}

test "nested error frames restore in order and release their pins" {
    clearLastError();
    last_error = Error{ .JsError = JsError.fromMessage(formatMessage("first", .{})) };
    const first = ErrorFrame.save();

    last_error = Error{ .JsError = JsError.fromMessage(formatMessage("second", .{})) };
    const second = ErrorFrame.save();

    last_error = Error{ .JsError = JsError.fromMessage(formatMessage("third", .{})) };
    second.restore();
    try std.testing.expectEqualStrings("second", messageOf(last_error.?));

    first.restore();
    try std.testing.expectEqualStrings("first", messageOf(last_error.?));

    clearLastError();
    for (message_slot_pins) |pins| {
        try std.testing.expectEqual(@as(u16, 0), pins);
    }
}

test "pending exception marker survives a frame" {
    clearLastError();
    setPendingException();
    const frame = ErrorFrame.save();
    clearLastError();
    try std.testing.expect(!hasPendingException());
    frame.restore();
    try std.testing.expect(hasPendingException());
    clearLastError();
}
