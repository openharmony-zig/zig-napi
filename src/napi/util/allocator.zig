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
///
/// Conversion allocates through this allocator. Callers that clean a converted
/// value up later must capture the allocator once (see `capture`) and pass it to
/// `Napi.deinit_napi_value_with_allocator`, so allocation and release always use
/// the same allocator. `napi.Owned` values record it explicitly.
pub fn globalAllocator() std.mem.Allocator {
    return global_manager.get();
}

/// Get the allocator used for values whose lifetime is owned by the JS runtime.
pub fn runtimeAllocator() std.mem.Allocator {
    return runtime_manager.get();
}

/// Read the current operation allocator once so a later cleanup can use exactly
/// the allocator that performed the allocation, even if the global was swapped
/// in the meantime.
pub fn capture() std.mem.Allocator {
    return global_manager.get();
}

/// Temporarily replace the operation allocator and restore the previous one on
/// scope exit. This is a *single* global switch shared by every thread, so it is
/// only safe while no other thread allocates; long lived resources must record
/// their allocator instead of relying on the global.
pub const ScopedOverride = struct {
    previous: std.mem.Allocator,

    pub fn enter(new_allocator: std.mem.Allocator) ScopedOverride {
        const previous = global_manager.get();
        global_manager.set(new_allocator);
        return .{ .previous = previous };
    }

    pub fn exit(self: ScopedOverride) void {
        global_manager.set(self.previous);
    }
};
