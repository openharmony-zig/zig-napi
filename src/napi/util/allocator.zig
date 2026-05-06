const std = @import("std");

pub const AllocatorManager = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .allocator = std.heap.page_allocator,
        };
    }

    pub fn get(self: *const Self) std.mem.Allocator {
        return self.allocator;
    }

    pub fn set(self: *Self, new_allocator: std.mem.Allocator) void {
        self.allocator = new_allocator;
    }
};

pub var global_manager = AllocatorManager.init();
pub var runtime_manager = AllocatorManager.init();

/// Get the global allocator
pub fn globalAllocator() std.mem.Allocator {
    return global_manager.get();
}

/// Get the allocator used for values whose lifetime is owned by the JS runtime.
pub fn runtimeAllocator() std.mem.Allocator {
    return runtime_manager.get();
}
