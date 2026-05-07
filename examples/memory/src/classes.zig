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
        const allocator = napi.globalAllocator();
        if (self.name.len > 0) {
            allocator.free(self.name);
        }
        if (self.values.len > 0) {
            allocator.free(self.values);
        }
        onClassFinalized();
    }
};

const MemoryWithoutInitData = struct {
    count: u32,

    const Self = @This();

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
        const allocator = napi.globalAllocator();
        if (self.name.len > 0) {
            allocator.free(self.name);
        }
        if (self.values.len > 0) {
            allocator.free(self.values);
        }
        onClassFinalized();
    }
};

pub const MemoryClass = napi.Class(MemoryClassData);
pub const MemoryClassWithoutInit = napi.ClassWithoutInit(MemoryWithoutInitData);
pub const MemoryFactoryClass = napi.Class(MemoryFactoryData);
