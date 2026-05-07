const std = @import("std");
const root = @import("root");

pub const AllocatorManager = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn get(self: *const Self) std.mem.Allocator {
        return self.allocator;
    }

    pub fn set(self: *Self, new_allocator: std.mem.Allocator) void {
        self.allocator = new_allocator;
    }
};

/// The addon root module may declare `pub const napi_allocator: std.mem.Allocator = ...;`.
/// The export scanner treats this name as reserved, while Zig still enforces that a
/// root declaration can only be defined once.
pub fn defaultAllocator() std.mem.Allocator {
    if (@hasDecl(root, "napi_allocator")) {
        const allocator = root.napi_allocator;
        if (@TypeOf(allocator) != std.mem.Allocator) {
            @compileError("root.napi_allocator must be a std.mem.Allocator");
        }
        return allocator;
    }

    return std.heap.page_allocator;
}

pub var global_manager = AllocatorManager.init(defaultAllocator());
pub var runtime_manager = AllocatorManager.init(defaultAllocator());

/// Get the global allocator
pub fn globalAllocator() std.mem.Allocator {
    return global_manager.get();
}

/// Get the allocator used for values whose lifetime is owned by the JS runtime.
pub fn runtimeAllocator() std.mem.Allocator {
    return runtime_manager.get();
}
