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
// Finalization and the init/factory input contract
// ---------------------------------------------------------------------------

var finalized_count = std.atomic.Value(usize).init(0);

pub fn finalizedCount() usize {
    return finalized_count.load(.monotonic);
}

pub fn resetFinalizedCount() void {
    finalized_count.store(0, .monotonic);
}

/// Keeps a borrowed init input in a field and mutates the field in `deinit`.
///
/// The converted input is owned by the wrapper, not by the type, so `deinit`
/// must not free it - and the wrapper must not read the value after `deinit`
/// has run (which clearing the field here detects).
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
        self.payload = &[_]u8{};
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const TrackedClass = napi.Class(Tracked);

/// Allocates its own payload in the factory and releases it in `deinit`: the
/// explicit form of resource ownership. A leaked instance shows up as a
/// positive `activeBytes` delta after GC.
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

/// The init input is a struct with a nested allocation; the wrapper has to
/// release the nested slice with the allocator that produced it.
const NestedPayload = struct {
    text: []const u8,
    count: i32,
};

const Nested = struct {
    payload: NestedPayload,

    pub fn init(payload: NestedPayload) Nested {
        return .{ .payload = payload };
    }

    pub fn describe(self: *Nested) []const u8 {
        return self.payload.text;
    }

    pub fn total(self: *Nested) i32 {
        return self.payload.count;
    }
};

pub const NestedClass = napi.Class(Nested);

/// Stores a sub-slice of a converted input. The wrapper owns the whole input
/// and releases it exactly once, so a sub-slice alias must not be freed twice.
const Aliased = struct {
    window: []const u8,

    pub fn init(payload: []const u8) Aliased {
        return .{ .window = if (payload.len > 1) payload[1..] else payload };
    }

    pub fn view(self: *Aliased) []const u8 {
        return self.window;
    }
};

pub const AliasedClass = napi.Class(Aliased);

/// The second argument is never stored: it is still owned by the wrapper and
/// must be released at finalization.
const UnusedArg = struct {
    value: i32,

    pub fn init(value: i32, unused: []const u8) UnusedArg {
        _ = unused;
        return .{ .value = value };
    }

    pub fn read(self: *UnusedArg) i32 {
        return self.value;
    }
};

pub const UnusedArgClass = napi.Class(UnusedArg);

/// The type owns its fields through `deinit`, so an implicit JavaScript
/// replacement of a field that carries native memory is refused instead of
/// orphaning the previous value. Plain data stays assignable.
const DeinitOwned = struct {
    name: []const u8,
    count: i32,

    pub fn init(name: []const u8, count: i32) DeinitOwned {
        return .{ .name = name, .count = count };
    }

    pub fn describe(self: *DeinitOwned) []const u8 {
        return self.name;
    }

    pub fn deinit(self: *DeinitOwned) void {
        self.name = &[_]u8{};
    }
};

pub const DeinitOwnedClass = napi.Class(DeinitOwned);

/// Field construction installs every field through the wrapper, so replacing a
/// field of a type with `deinit` is allowed - the wrapper owns the value it
/// installed.
const FieldBuilt = struct {
    label: []const u8,

    pub fn deinit(self: *FieldBuilt) void {
        self.label = &[_]u8{};
    }
};

pub const FieldBuiltClass = napi.Class(FieldBuilt);

/// A field type that owns itself through `deinit`.
const Payload = struct {
    text: []u8,

    pub fn deinit(self: *Payload) void {
        if (self.text.len > 0) napi.globalAllocator().free(self.text);
        self.text = &[_]u8{};
    }
};

/// Explicit owner contract: the field type declares `deinit`, so replacing the
/// field releases the previous value through that `deinit` even when the
/// wrapper did not install it.
const ExplicitOwner = struct {
    payload: Payload,

    pub fn init() ExplicitOwner {
        return .{ .payload = .{ .text = &[_]u8{} } };
    }

    pub fn size(self: *ExplicitOwner) usize {
        return self.payload.text.len;
    }

    pub fn deinit(self: *ExplicitOwner) void {
        self.payload.deinit();
    }
};

pub const ExplicitOwnerClass = napi.Class(ExplicitOwner);

// ---------------------------------------------------------------------------
// Provenance: a foreign `napi_wrap` payload must never be dereferenced
// ---------------------------------------------------------------------------

/// Wraps an opaque foreign payload (pointer 1, which is not a readable
/// allocation) into an object of this addon.
pub fn foreignObject(env: napi.Env) !napi.Object {
    const object = try napi.Object.Create(env);
    const api = napi.napi_sys.napi_sys;
    if (api.napi_wrap(env.raw, object.raw, @ptrFromInt(1), null, null, null) != api.napi_ok) {
        return error.WrapFailed;
    }
    return object;
}

/// Reads a wrapper payload and returns its first byte, proving that the native
/// body only runs when the wrapper is valid.
pub fn firstByte(view: napi.Uint8Array) !u32 {
    _ = typed_array_calls.fetchAdd(1, .monotonic);
    const slice = try view.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

var typed_array_calls = std.atomic.Value(usize).init(0);

pub fn typedArrayCalls() usize {
    return typed_array_calls.load(.monotonic);
}

pub fn resetTypedArrayCalls() void {
    typed_array_calls.store(0, .monotonic);
}

// ---------------------------------------------------------------------------
// F12: binary wrappers must re-validate after JavaScript reentry
// ---------------------------------------------------------------------------

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
