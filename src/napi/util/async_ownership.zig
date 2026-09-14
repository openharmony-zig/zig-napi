//! Adapters between the async subsystems and the ownership contract of the
//! conversion layer:
//!
//! * `Napi.clone_napi_value` / `Napi.deinit_napi_value_with_allocator` deep-copy
//!   and release native value shapes (JavaScript handles are rejected at compile
//!   time),
//! * `Napi.containsOwnedValue` / `Napi.disposeOwnedParts` release exactly the
//!   explicit `napi.Owned(T)` nodes of an otherwise borrowed value,
//! * plain native returns stay borrowed: only `Owned` transfers ownership.
//!
//! Everything here is a thin re-export plus `ErrorSnapshot`, which copies the
//! borrowed text of an error into memory owned by the receiver before the error
//! crosses a thread boundary.

const std = @import("std");
const Napi = @import("./napi.zig").Napi;
const helper = @import("./helper.zig");
const NapiError = @import("../wrapper/error.zig");

/// Deep-copy `value` into memory owned by `allocator`.
pub fn cloneValue(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    return Napi.clone_napi_value(T, value, allocator);
}

/// Dispose a value whose memory is owned by `allocator`.
///
/// Only call this for values this module allocated (for example a clone), never
/// for borrowed values or static literals.
pub fn deinitValue(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    Napi.deinit_napi_value_with_allocator(T, value, allocator);
}

/// Dispose the explicitly owned parts of a value that is otherwise borrowed.
///
/// Plain slices, literals and JavaScript handles are left untouched.
pub fn disposeOwnedParts(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    Napi.disposeOwnedParts(T, value, allocator);
}

/// True when `T` can contain an explicit `Owned(T)` node somewhere.
pub fn containsOwned(comptime T: type) bool {
    return Napi.containsOwnedValue(T);
}

/// True when `T` is an explicit `napi.Owned(T)` wrapper.
pub fn isOwnedValue(comptime T: type) bool {
    return helper.isOwned(T);
}

/// An error whose borrowed text has been copied into caller-owned memory.
///
/// Errors created on a background thread may point at that thread's rotating
/// message slots or at buffers of a captured input. The completion is converted
/// on the JavaScript thread, so the text must be copied before the error
/// crosses the thread boundary and released after the conversion.
pub const ErrorSnapshot = struct {
    allocator: std.mem.Allocator,
    stored: NapiError.Error,
    message: ?[]u8 = null,
    code: ?[]u8 = null,

    const Self = @This();

    pub fn capture(allocator: std.mem.Allocator, err: NapiError.Error) Self {
        var snapshot = Self{ .allocator = allocator, .stored = err };
        const text = stringsOf(err);

        if (text.message.len != 0) {
            if (allocator.dupe(u8, text.message)) |copy| {
                snapshot.message = copy;
                snapshot.stored = replaceStrings(snapshot.stored, copy, text.code);
            } else |_| {
                // The source may be a stack buffer or thread-local message slot;
                // never retain it across threads, even on allocation failure.
                return allocationFailure(allocator);
            }
        }

        const code = text.code orelse return snapshot;
        if (code.len == 0) return snapshot;
        if (allocator.dupe(u8, code)) |copy| {
            snapshot.code = copy;
            snapshot.stored = replaceStrings(snapshot.stored, snapshot.message orelse text.message, copy);
        } else |_| {
            snapshot.deinit();
            return allocationFailure(allocator);
        }
        return snapshot;
    }

    fn allocationFailure(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .stored = NapiError.Error.withCodeAndMessage("ERR_NAPI_ERROR_SNAPSHOT_OOM", "Unable to copy native error details"),
        };
    }

    /// Error value whose text is owned by this snapshot.
    pub fn value(self: Self) NapiError.Error {
        return self.stored;
    }

    pub fn deinit(self: *Self) void {
        if (self.message) |text| self.allocator.free(text);
        if (self.code) |code| self.allocator.free(code);
        self.message = null;
        self.code = null;
    }
};

fn stringsOf(err: NapiError.Error) struct { message: []const u8, code: ?[]const u8 } {
    return switch (err) {
        .JsError => |inner| .{ .message = inner.message, .code = inner.custom_status },
        .JsTypeError => |inner| .{ .message = inner.message, .code = inner.custom_status },
        .JsRangeError => |inner| .{ .message = inner.message, .code = inner.custom_status },
    };
}

fn replaceStrings(err: NapiError.Error, message: []const u8, code: ?[]const u8) NapiError.Error {
    return switch (err) {
        .JsError => |inner| .{ .JsError = .{
            .status = inner.status,
            .message = message,
            .mode = inner.mode,
            .custom_status = code,
        } },
        .JsTypeError => |inner| .{ .JsTypeError = .{
            .status = inner.status,
            .message = message,
            .mode = inner.mode,
            .custom_status = code,
        } },
        .JsRangeError => |inner| .{ .JsRangeError = .{
            .status = inner.status,
            .message = message,
            .mode = inner.mode,
            .custom_status = code,
        } },
    };
}

test "error snapshots own their text" {
    const allocator = std.testing.allocator;
    var buffer: [32]u8 = undefined;
    const borrowed = std.fmt.bufPrint(&buffer, "borrowed message", .{}) catch unreachable;

    var snapshot = ErrorSnapshot.capture(allocator, NapiError.Error.withReason(borrowed));
    defer snapshot.deinit();

    @memset(&buffer, 'x');
    const restored = snapshot.value();
    try std.testing.expectEqualStrings("borrowed message", restored.JsError.message);
    try std.testing.expect(restored.JsError.message.ptr != borrowed.ptr);
}

test "error snapshot allocation failure never retains borrowed text" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var message = [_]u8{ 'o', 'o', 'p', 's' };
        var code = [_]u8{ 'E', 'R', 'R' };
        var snapshot = ErrorSnapshot.capture(failing.allocator(), NapiError.Error.withCodeAndMessage(&code, &message));
        defer snapshot.deinit();
        @memset(&message, 'x');
        @memset(&code, 'x');
        try std.testing.expectEqualStrings("Unable to copy native error details", snapshot.value().JsError.message);
        try std.testing.expectEqualStrings("ERR_NAPI_ERROR_SNAPSHOT_OOM", snapshot.value().JsError.custom_status.?);
    }
}
