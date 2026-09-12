//! Ownership adapter for the async subsystems.
//!
//! The conversion layer is being migrated to an explicit ownership contract:
//!   * `Napi.clone_napi_value(T, value, allocator) !T`
//!   * `Napi.deinit_napi_value_with_allocator(T, value, allocator)`
//!   * `napi.Owned(T)` values are disposed through `Owned(T).deinit()`.
//!
//! This file is a TEMPORARY bridge used by `async.zig`, `worker.zig` and
//! `thread_safe_function.zig` while that migration is in flight. Every entry
//! point dispatches on `@hasDecl` at comptime, so as soon as the core helpers
//! exist the fallbacks below become unreachable and this file can be deleted
//! (the async modules can then import `Napi`/`napi.Owned` directly).
//!
//! Fallback semantics intentionally match the contract:
//!   * native value shapes (slices, arrays, tuples, structs, optionals, tagged
//!     unions, numbers, bools, enums) are deep-copied;
//!   * JS-backed handles (anything carrying `env`+`raw`/`raw_ref`) are rejected,
//!     because a JS handle cannot be silently declared safe for background use;
//!   * plain (borrowed) results are never freed: only explicit `Owned(T)`
//!     values are disposed by `disposeOwnedParts`.
//!
//! Limitation of the fallback (not of the core contract): `std.ArrayList`-like
//! values are copied/deinitialized structurally instead of through their
//! collection API.

const std = @import("std");
const Napi = @import("./napi.zig").Napi;
const helper = @import("./helper.zig");
const NapiError = @import("../wrapper/error.zig");

/// True when the core conversion layer already provides the ownership helpers.
pub const core_has_clone = @hasDecl(Napi, "clone_napi_value");
pub const core_has_deinit = @hasDecl(Napi, "deinit_napi_value_with_allocator");

/// Error used when a value cannot be copied into ownership of another thread.
pub const CloneError = error{NotCloneable};

/// Deep-copy `value` into memory owned by `allocator`.
///
/// Prefers `Napi.clone_napi_value` once it exists.
pub fn cloneValue(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    if (comptime core_has_clone) {
        return Napi.clone_napi_value(T, value, allocator);
    }
    return cloneFallback(T, value, allocator);
}

/// Dispose a value whose memory is owned by `allocator`.
///
/// Prefers `Napi.deinit_napi_value_with_allocator` once it exists. Only call
/// this for values this module allocated (for example a clone), never for
/// borrowed values or static literals.
pub fn deinitValue(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    if (comptime core_has_deinit) {
        Napi.deinit_napi_value_with_allocator(T, value, allocator);
        return;
    }
    deinitFallback(T, value, allocator);
}

/// True when `T` is an explicit `napi.Owned(T)`-style wrapper.
///
/// Detected structurally so this file keeps working before the wrapper type is
/// exported, and via `is_napi_owned` once it is.
pub fn isOwnedValue(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "is_napi_owned")) {
        return @TypeOf(@field(T, "is_napi_owned")) == bool and @field(T, "is_napi_owned");
    }
    return @hasField(T, "value") and @hasField(T, "allocator") and @hasDecl(T, "deinit");
}

/// True when `T` can contain an explicit `Owned(T)` node somewhere.
///
/// Used to skip cleanup walks entirely for ordinary borrowed values: a borrowed
/// slice may alias memory that was already released, so it must never be read
/// during cleanup.
pub fn containsOwned(comptime T: type) bool {
    if (comptime isOwnedValue(T)) return true;
    switch (@typeInfo(T)) {
        .optional => |optional| return containsOwned(optional.child),
        .array => |array| return containsOwned(array.child),
        .pointer => |ptr| return ptr.size == .slice and containsOwned(ptr.child),
        .@"struct" => |struct_info| {
            if (isJsHandle(T)) return false;
            inline for (struct_info.fields) |field| {
                if (comptime containsOwned(field.type)) return true;
            }
            return false;
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return false;
            inline for (union_info.fields) |field| {
                if (comptime containsOwned(field.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Dispose the explicitly owned parts of a value that is otherwise borrowed.
///
/// Plain slices, literals and JS handles are left untouched; only `Owned(T)`
/// nodes are deinitialized. This is the cleanup path for async/worker results,
/// which are borrowed unless the runner wrapped them in `Owned(T)`.
pub fn disposeOwnedParts(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    if (comptime !containsOwned(T)) return;

    if (comptime isOwnedValue(T)) {
        var mutable = value;
        mutable.deinit();
        return;
    }

    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (value) |payload| disposeOwnedParts(optional.child, payload, allocator);
        },
        .array => |array| {
            for (value) |item| disposeOwnedParts(array.child, item, allocator);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                for (value) |item| disposeOwnedParts(ptr.child, item, allocator);
            }
        },
        .@"struct" => |struct_info| {
            if (isJsHandle(T)) return;
            inline for (struct_info.fields) |field| {
                disposeOwnedParts(field.type, @field(value, field.name), allocator);
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return;
            switch (value) {
                inline else => |payload| disposeOwnedParts(@TypeOf(payload), payload, allocator),
            }
        },
        else => {},
    }
}

/// True when the type is a JS-backed handle that must not cross a thread
/// boundary without an explicit copy API.
pub fn isJsHandle(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (@hasField(T, "raw") and @hasField(T, "env")) return true;
    if (@hasField(T, "raw_ref")) return true;
    if (@hasField(T, "tsfn_raw")) return true;
    return false;
}

fn notCloneable(comptime T: type) CloneError {
    NapiError.last_error = NapiError.Error.withCodeAndMessage(
        "ERR_NAPI_NOT_CLONEABLE",
        "Value of type " ++ @typeName(T) ++ " cannot be copied for use outside the calling JavaScript scope",
    );
    return error.NotCloneable;
}

fn cloneFallback(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .error_set, .@"fn", .null, .undefined, .void, .noreturn, .type => return value,
        .optional => |optional| {
            if (value) |payload| {
                return try cloneFallback(optional.child, payload, allocator);
            }
            return null;
        },
        .array => |array| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer for (out[0..initialized]) |item| deinitFallback(array.child, item, allocator);
            for (value, 0..) |item, index| {
                out[index] = try cloneFallback(array.child, item, allocator);
                initialized = index + 1;
            }
            return out;
        },
        .vector => return value,
        .pointer => |ptr| {
            if (ptr.size != .slice) return notCloneable(T);
            if (value.len == 0) {
                const empty = try allocator.alloc(ptr.child, 0);
                return empty;
            }
            const out = try allocator.alloc(ptr.child, value.len);
            errdefer allocator.free(out);
            if (comptime isOpaqueElement(ptr.child)) {
                @memcpy(std.mem.sliceAsBytes(out), std.mem.sliceAsBytes(value));
                return out;
            }
            var initialized: usize = 0;
            errdefer for (out[0..initialized]) |item| deinitFallback(ptr.child, item, allocator);
            for (value, 0..) |item, index| {
                out[index] = try cloneFallback(ptr.child, item, allocator);
                initialized = index + 1;
            }
            return out;
        },
        .@"struct" => |struct_info| {
            if (isJsHandle(T)) return notCloneable(T);
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (struct_info.fields, 0..) |field, index| {
                if (index < initialized) deinitFallback(field.type, @field(out, field.name), allocator);
            };
            inline for (struct_info.fields) |field| {
                @field(out, field.name) = try cloneFallback(field.type, @field(value, field.name), allocator);
                initialized += 1;
            }
            return out;
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return notCloneable(T);
            return switch (value) {
                inline else => |payload| @unionInit(T, @tagName(value), try cloneFallback(@TypeOf(payload), payload, allocator)),
            };
        },
        else => return value,
    }
}

fn deinitFallback(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (value) |payload| deinitFallback(optional.child, payload, allocator);
        },
        .array => |array| {
            for (value) |item| deinitFallback(array.child, item, allocator);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and value.len != 0) allocator.free(value);
        },
        .@"struct" => |struct_info| {
            if (isJsHandle(T)) return;
            if (comptime hasDisposableDeinit(T)) {
                var mutable = value;
                if (comptime deinitTakesAllocator(T)) {
                    mutable.deinit(allocator);
                } else {
                    mutable.deinit();
                }
                return;
            }
            inline for (struct_info.fields) |field| {
                deinitFallback(field.type, @field(value, field.name), allocator);
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return;
            switch (value) {
                inline else => |payload| deinitFallback(@TypeOf(payload), payload, allocator),
            }
        },
        else => {},
    }
}

fn isOpaqueElement(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .pointer, .@"fn", .void => true,
        else => false,
    };
}

fn hasDisposableDeinit(comptime T: type) bool {
    if (!@hasDecl(T, "deinit")) return false;
    const deinit_info = @typeInfo(@TypeOf(@field(T, "deinit")));
    if (deinit_info != .@"fn") return false;
    const params = deinit_info.@"fn".params;
    return params.len >= 1 and params.len <= 2;
}

fn deinitTakesAllocator(comptime T: type) bool {
    const deinit_info = @typeInfo(@TypeOf(@field(T, "deinit"))).@"fn";
    if (deinit_info.params.len != 2) return false;
    return deinit_info.params[1].type == std.mem.Allocator;
}

test "cloneFallback deep copies slices and structs" {
    const allocator = std.testing.allocator;
    const Shape = struct { label: []const u8, values: []const f32 };
    const original = Shape{ .label = "hello", .values = &.{ 1.0, 2.0 } };

    const cloned = try cloneValue(Shape, original, allocator);
    defer deinitValue(Shape, cloned, allocator);

    try std.testing.expectEqualStrings("hello", cloned.label);
    try std.testing.expect(cloned.label.ptr != original.label.ptr);
    try std.testing.expect(cloned.values.ptr != original.values.ptr);
    try std.testing.expectEqual(@as(f32, 2.0), cloned.values[1]);
}

test "cloneValue rejects JS handles" {
    const Handle = struct { env: ?*anyopaque, raw: ?*anyopaque };
    try std.testing.expectError(error.NotCloneable, cloneValue(Handle, .{ .env = null, .raw = null }, std.testing.allocator));
}

test "disposeOwnedParts ignores borrowed values" {
    const allocator = std.testing.allocator;
    const Owned = struct {
        value: []u8,
        allocator: std.mem.Allocator,
        pub const is_napi_owned = true;

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.value);
        }
    };

    const Borrowed = struct { text: []const u8, count: u32 };
    disposeOwnedParts(Borrowed, .{ .text = "literal", .count = 1 }, allocator);

    const label = try allocator.dupe(u8, "owned");
    const holder = struct { label: Owned, other: []const u8 }{ .label = .{ .value = label, .allocator = allocator }, .other = "literal" };
    disposeOwnedParts(@TypeOf(holder), holder, allocator);
}
