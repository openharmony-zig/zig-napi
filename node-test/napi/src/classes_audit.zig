//! Regression harness for the class wrapper and the binary wrappers.
//!
//! Audit items covered here:
//!   F05 per environment class constructor references
//!   F06 static methods, factories and ClassWithoutInit construction
//!   F07 constructor rollback and setter replacement ownership
//!   F12 detached / invalidated backing stores for TypedArray, DataView,
//!       ArrayBuffer and Buffer.
//!
//! The addon is built with a counting allocator so that the leak assertions in
//! `node-test/napi/__tests__/classes-audit.spec.js` measure real allocations.
const std = @import("std");
const napi = @import("napi");
const counting = @import("counting");

var counter = counting.CountingAllocator.init(std.heap.page_allocator);

pub const napi_allocator = counter.allocator();

/// Native allocations that are still alive. The tests compare deltas around a
/// loop so that unrelated allocations do not affect the assertion.
pub fn activeBytes() isize {
    return counter.stats().active_bytes;
}

pub fn activeAllocations() isize {
    return counter.stats().active_allocations;
}

// ---------------------------------------------------------------------------
// F07: default field construction, setter replacement and rollback
// ---------------------------------------------------------------------------

const TextState = struct {
    text: []const u8,
    count: i32,
};

pub const TextClass = napi.Class(TextState);

// ---------------------------------------------------------------------------
// F06: init, static methods, value receivers, factories and static values
// ---------------------------------------------------------------------------

var widget_init_calls = std.atomic.Value(usize).init(0);

pub fn widgetInitCalls() usize {
    return widget_init_calls.load(.monotonic);
}

pub fn resetWidgetInitCalls() void {
    widget_init_calls.store(0, .monotonic);
}

const Widget = struct {
    value: i32,

    pub const KIND: []const u8 = "widget";

    /// Running `init` twice (for example from a factory that reuses the
    /// constructor path) is observable through this counter and through the
    /// value offset.
    pub fn init(value: i32) Widget {
        _ = widget_init_calls.fetchAdd(1, .monotonic);
        return .{ .value = value };
    }

    pub fn make(value: i32) Widget {
        return .{ .value = value };
    }

    /// Static method: its `this` is the constructor, it must not unwrap it.
    pub fn twice(value: i32) i32 {
        return value * 2;
    }

    pub fn bump(self: *Widget, delta: i32) i32 {
        self.value += delta;
        return self.value;
    }

    /// Value receiver; the documentation promises this form works.
    pub fn read(self: Widget) i32 {
        return self.value;
    }
};

pub const WidgetClass = napi.Class(Widget);

const Labeled = struct {
    label: []const u8,
    value: i32,

    pub fn init(label: []const u8, value: i32) Labeled {
        return .{ .label = label, .value = value };
    }

    pub fn make(label: []const u8, value: i32) Labeled {
        return .{ .label = label, .value = value };
    }

    pub fn describe(self: *Labeled) []const u8 {
        return self.label;
    }
};

pub const LabeledClass = napi.Class(Labeled);

const NoInitState = struct {
    value: i32,

    pub fn make(value: i32) NoInitState {
        return .{ .value = value };
    }

    pub fn add(self: *NoInitState, delta: i32) i32 {
        self.value += delta;
        return self.value;
    }
};

pub const NoInitClass = napi.ClassWithoutInit(NoInitState);

// ---------------------------------------------------------------------------
// Finalization: a `deinit` must run exactly once per instance
// ---------------------------------------------------------------------------

var finalized_count = std.atomic.Value(usize).init(0);

pub fn finalizedCount() usize {
    return finalized_count.load(.monotonic);
}

pub fn resetFinalizedCount() void {
    finalized_count.store(0, .monotonic);
}

const Tracked = struct {
    payload: []const u8,

    pub fn init(payload: []const u8) Tracked {
        return .{ .payload = payload };
    }

    pub fn make(payload: []const u8) Tracked {
        return .{ .payload = payload };
    }

    pub fn size(self: *Tracked) usize {
        return self.payload.len;
    }

    pub fn deinit(self: *Tracked) void {
        // The type declares ownership of its buffers, which is what the
        // wrapper expects for types with a custom `deinit`.
        const allocator = napi.globalAllocator();
        if (self.payload.len > 0) {
            allocator.free(@constCast(self.payload));
        }
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const TrackedClass = napi.Class(Tracked);

/// Allocates its own payload in the factory; `deinit` releases it, so a leaked
/// instance shows up as a positive `activeBytes` delta after GC.
const Owned = struct {
    payload: []const u8,

    pub fn make(text: []const u8) !Owned {
        const allocator = napi.globalAllocator();
        const owned = try allocator.dupe(u8, text);
        return .{ .payload = owned };
    }

    pub fn size(self: *Owned) usize {
        return self.payload.len;
    }

    pub fn deinit(self: *Owned) void {
        const allocator = napi.globalAllocator();
        if (self.payload.len > 0) {
            allocator.free(@constCast(self.payload));
        }
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const OwnedClass = napi.ClassWithoutInit(Owned);

// ---------------------------------------------------------------------------
// F12: binary wrappers must re-validate after JavaScript reentry
// ---------------------------------------------------------------------------

pub fn firstByte(view: napi.Uint8Array) !u32 {
    const slice = try view.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn firstByteAfterCallback(view: napi.Uint8Array, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try view.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

/// Reads through the unchecked accessor: after a detach this must not return
/// the stale first byte any more.
pub fn firstByteUncheckedAfterCallback(view: napi.Uint8Array, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = view.asSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn dataViewByteAfterCallback(view: napi.DataView, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    return try view.getUint8(0);
}

pub fn bufferFirstByteAfterCallback(buffer: napi.Buffer, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try buffer.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn arrayBufferFirstByteAfterCallback(buffer: napi.ArrayBuffer, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try buffer.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn typedArraySum(input: napi.Uint32Array) !u32 {
    var sum: u32 = 0;
    for (try input.tryAsSlice()) |value| {
        sum +%= value;
    }
    return sum;
}

/// Creating a view whose byte range overflows `usize` must fail instead of
/// wrapping into a valid looking view.
pub fn typedArrayOverflow(env: napi.Env, buffer: napi.ArrayBuffer) !void {
    _ = try napi.Uint8Array.fromArrayBuffer(env, buffer, std.math.maxInt(usize), 0);
}

pub fn dataViewOverflow(env: napi.Env, buffer: napi.ArrayBuffer) !void {
    _ = try napi.DataView.fromArrayBuffer(env, buffer, std.math.maxInt(usize), 16);
}

comptime {
    napi.NODE_API_MODULE("classes_audit", @This());
}
