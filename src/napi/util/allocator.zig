const std = @import("std");

pub var global_allocator: std.mem.Allocator = std.heap.page_allocator;

const self = @This();

/// Default allocator
pub fn globalAllocator() std.mem.Allocator {
    return self.global_allocator;
}

/// Set the global allocator
pub fn setGlobalAllocator(new_allocator: std.mem.Allocator) void {
    self.global_allocator = new_allocator;
}
