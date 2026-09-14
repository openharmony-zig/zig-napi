//! Native value ownership.
//!
//! The contract has two directions and they are not symmetric:
//!
//! * **Converted JavaScript arguments are owned by the call scope.** Reading a
//!   string, array, struct or optional argument allocates a native copy, and the
//!   exporting call releases that copy when it returns - on the success path and
//!   on the failure path. Inside the exported function the argument memory is
//!   valid, but it must not be stored anywhere that outlives the call (a
//!   background thread, an async descriptor, a global) unless it is deep-copied
//!   with `Napi.clone_napi_value` or `Owned.clone`. Merely wrapping a borrowed
//!   argument in `Owned.init` does not transfer the call scope's ownership.
//! * **Plain native returns are borrowed.** Whatever an exported function hands
//!   back - a static literal, a sub-slice of one of its arguments, an alias of
//!   caller memory - is copied into a JavaScript value and never freed by the
//!   framework. Freshly allocated native memory must therefore be returned as
//!   `Owned(T)`; otherwise it leaks.
//!
//! `Owned(T)` is the only thing that transfers native ownership. It knows the
//! allocator that created the payload and must be released exactly once:
//!
//! * it converts like its payload (the data is copied into JavaScript first),
//! * it is disposed right after that conversion finishes, on success and when the
//!   output conversion fails,
//! * `Owned` nodes nested inside an otherwise borrowed return (`Owned` fields,
//!   optional/array/slice/union cases of `Owned`) are disposed too, while plain
//!   borrowed containers, literals and aliases are left untouched,
//! * it is deep-copied by `clone_napi_value` together with its allocator,
//! * it is recursively cleaned up by `deinit_napi_value_with_allocator`.
//!
//! `Owned` claims *exclusive* ownership of the payload. Never wrap memory that
//! the call scope already releases (an argument, a sub-slice of one) or a static
//! literal: wrapping it a second time would free it twice.
//!
//! "Exclusive" is about the right to free, not about the bytes: `borrow()` and
//! `take()` both hand out the same pointer, so aliases stay valid as long as the
//! owner has not released them yet. Only one of them may end up being freed, and
//! the aliases must not be freed at all.
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

        /// Hand the payload to another owner without releasing it here.
        ///
        /// `self` is passed by value, so this does not invalidate the original
        /// `Owned`: both copies refer to the same bytes, exactly like two aliases
        /// of the same slice. The caller that received the payload becomes
        /// responsible for releasing it with `self.allocator`, and every other
        /// copy must be dropped *without* calling `deinit`. `take()` never frees
        /// anything and never invalidates existing aliases.
        pub fn take(self: Self) T {
            return self.value;
        }

        /// Borrow the payload without changing ownership at all.
        /// The returned value is valid while `self` is alive and must not be freed.
        pub fn borrow(self: Self) T {
            return self.value;
        }

        /// Allocator that owns the payload; use it when moving the payload to a
        /// new owner through `take()`.
        pub fn ownerAllocator(self: Self) std.mem.Allocator {
            return self.allocator;
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
