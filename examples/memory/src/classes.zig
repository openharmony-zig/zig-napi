const std = @import("std");
const napi = @import("napi");
const finalizer_state = @import("finalizer_state.zig");

var class_finalizers = std.atomic.Value(usize).init(0);

fn onClassFinalized() void {
    _ = class_finalizers.fetchAdd(1, .monotonic);
    finalizer_state.onClassFinalized();
}

pub fn reset_class_finalizer_count() void {
    class_finalizers.store(0, .monotonic);
}

pub fn class_finalizer_count() usize {
    return class_finalizers.load(.monotonic);
}

const MemoryClassData = struct {
    name: []u8,
    values: []f32,

    const Self = @This();

    /// The converted constructor arguments are borrowed: the class wrapper owns
    /// them and releases them right after `deinit` has run. A type that has to
    /// own a resource must clone it explicitly (`napi.clone_napi_value`) or
    /// store it in an explicitly owned field (`napi.Owned`).
    pub fn init(name: []u8, values: []f32) Self {
        return .{ .name = name, .values = values };
    }

    pub fn total(self: *Self) f64 {
        var sum: f64 = 0;
        for (self.values) |value| {
            sum += value;
        }
        return sum;
    }

    pub fn deinit(self: *Self) void {
        // Never free a borrowed input here: it is not this instance's memory.
        // Clearing the fields also documents that nothing may be read from the
        // value after `deinit` returned.
        self.name = &[_]u8{};
        self.values = &[_]f32{};
        onClassFinalized();
    }
};

const MemoryWithoutInitData = struct {
    count: u32,

    const Self = @This();

    /// `ClassWithoutInit` rejects JavaScript construction, so the factory is
    /// the only construction path.
    pub fn make() Self {
        return .{ .count = 0 };
    }

    pub fn total(self: *Self) u32 {
        return self.count;
    }

    pub fn deinit(_: *Self) void {
        onClassFinalized();
    }
};

const MemoryFactoryData = struct {
    name: []u8,
    values: []f32,

    const Self = @This();

    /// Factory arguments are borrowed exactly like constructor arguments; the
    /// wrapper releases them when the instance is finalized.
    pub fn initWithFactory(name: []u8, values: []f32) Self {
        return .{ .name = name, .values = values };
    }

    pub fn total(self: *Self) f64 {
        var sum: f64 = 0;
        for (self.values) |value| {
            sum += value;
        }
        return sum;
    }

    pub fn deinit(self: *Self) void {
        self.name = &[_]u8{};
        self.values = &[_]f32{};
        onClassFinalized();
    }
};

pub const MemoryClass = napi.Class(MemoryClassData);
pub const MemoryClassWithoutInit = napi.ClassWithoutInit(MemoryWithoutInitData);
pub const MemoryFactoryClass = napi.Class(MemoryFactoryData);
