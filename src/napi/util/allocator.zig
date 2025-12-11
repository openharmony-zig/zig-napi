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

pub const global_manager = AllocatorManager.init();

/// Get the global allocator
pub fn globalAllocator() std.mem.Allocator {
    return global_manager.get();
}

/// Set a custom global allocator
pub fn setGlobalAllocator(new_allocator: std.mem.Allocator) void {
    global_manager.set(new_allocator);
}
