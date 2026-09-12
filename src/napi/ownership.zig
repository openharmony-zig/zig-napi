//! Native value ownership.
//!
//! Conversion allocates native copies of JavaScript data (strings, arrays,
//! structs). Those copies are *borrowed* by default: the conversion layer does
//! not free them, which keeps literals, sub-slices of caller memory and other
//! static data safe.
//!
//! `Owned(T)` marks the other half of the contract: a value that was allocated
//! natively, knows the allocator that created it, and must be released exactly
//! once. Values wrapped in `Owned` are:
//!
//! * converted like their payload when they are converted to a JavaScript value,
//! * disposed right after that conversion finishes,
//! * deep-copied by `clone_napi_value` together with their allocator,
//! * recursively cleaned up by `deinit_napi_value_with_allocator`.
//!
//! `Owned` claims exclusive ownership. Never wrap memory that was borrowed from
//! a function argument, a sub-slice of one, or a static literal: the call scope
//! already releases the argument copy, so wrapping it again would free it twice.
const std = @import("std");
const Napi = @import("./util/napi.zig").Napi;
const helper = @import("./util/helper.zig");

/// Explicitly owned native value.
///
/// ```zig
/// pub fn allocate() napi.Owned([]const u8) {
///     const allocator = napi.globalAllocator();
///     return .init(allocator.dupe(u8, "owned") catch unreachable, allocator);
/// }
/// ```
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Marker used by the conversion layer to recognize owned values.
        pub const is_napi_owned = true;
        pub const owned_payload_type = T;

        pub fn init(value: T, allocator: std.mem.Allocator) Self {
            return .{ .value = value, .allocator = allocator };
        }

        /// Deep-copy `source` into freshly allocated native memory owned by `allocator`.
        /// Fails for values that contain JavaScript handles: those cannot be moved
        /// to another thread or freed by native code.
        pub fn clone(source: T, allocator: std.mem.Allocator) !Self {
            return Self.init(try Napi.clone_napi_value(T, source, allocator), allocator);
        }

        /// Release every native allocation owned by this value exactly once.
        pub fn deinit(self: *Self) void {
            Napi.deinit_napi_value_with_allocator(T, self.value, self.allocator);
        }

        /// Give up ownership without releasing the payload.
        /// The caller becomes the owner and must release it with the same allocator.
        pub fn take(self: Self) T {
            return self.value;
        }

        /// Borrow the payload. The returned value is only valid while `self` is alive.
        pub fn borrow(self: Self) T {
            return self.value;
        }
    };
}

/// True when `T` is an `Owned` wrapper produced by `napi.Owned`.
pub fn isOwned(comptime T: type) bool {
    return helper.isOwned(T);
}

/// Payload type of an `Owned` wrapper.
pub fn ownedPayload(comptime T: type) type {
    return helper.ownedPayload(T);
}
