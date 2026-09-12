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
///
/// This allocator is the *default* for every thread, so it is reached
/// concurrently: it must be safe to allocate and free from multiple threads at
/// the same time (atomics, a lock, or a system allocator).
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

/// Operation allocator of the *current thread*.
///
/// The manager is thread local: `set` (and therefore `setOperationAllocator`)
/// only replaces the calling thread's allocator, so two threads can work with
/// different allocators without disturbing each other. Every thread starts from
/// `defaultAllocator()`.
pub threadlocal var global_manager = AllocatorManager.init(defaultAllocator());

/// Allocator used for values whose lifetime is owned by the JS runtime.
/// Thread local for the same reason as `global_manager`.
pub threadlocal var runtime_manager = AllocatorManager.init(defaultAllocator());

/// Get the operation allocator of the current thread.
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
/// the allocator that performed the allocation, even if this thread replaced it
/// in the meantime.
pub fn capture() std.mem.Allocator {
    return global_manager.get();
}

/// Bookkeeping for nested `ScopedOverride`s of the current thread.
const max_override_depth = 16;
threadlocal var override_stack: [max_override_depth]std.mem.Allocator = undefined;
threadlocal var override_depth: usize = 0;

/// Temporarily replace the current thread's operation allocator and restore the
/// previous one on scope exit.
///
/// Overrides are per thread and nest: entering twice restores the intermediate
/// allocator when the inner scope exits, and the thread's original allocator
/// when the outer scope exits. An override must be entered and exited on the
/// same thread.
pub const ScopedOverride = struct {
    /// Allocator that was active when the scope was entered.
    previous: std.mem.Allocator,
    /// One-based nesting depth, or 0 when the bookkeeping stack was full.
    depth: usize,

    pub fn enter(new_allocator: std.mem.Allocator) ScopedOverride {
        const previous = global_manager.get();
        if (override_depth >= max_override_depth) {
            // Deeper than the bookkeeping stack: still restore correctly for
            // strictly nested scopes, but without out-of-order protection.
            global_manager.set(new_allocator);
            return .{ .previous = previous, .depth = 0 };
        }

        const depth = override_depth;
        override_stack[depth] = previous;
        override_depth = depth + 1;
        global_manager.set(new_allocator);
        return .{ .previous = previous, .depth = depth + 1 };
    }

    pub fn exit(self: ScopedOverride) void {
        if (self.depth == 0) {
            global_manager.set(self.previous);
            return;
        }

        const index = self.depth - 1;
        global_manager.set(override_stack[index]);
        override_depth = @min(override_depth, index);
    }
};

// ---------------------------------------------------------------------- tests

const TaggedAllocator = struct {
    backing: std.mem.Allocator,
    allocations: std.atomic.Value(usize) = .init(0),
    frees: std.atomic.Value(usize) = .init(0),

    const Self = @This();

    fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn counts(self: *Self) struct { allocations: usize, frees: usize } {
        return .{
            .allocations = self.allocations.load(.monotonic),
            .frees = self.frees.load(.monotonic),
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.frees.fetchAdd(1, .monotonic);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Identity of the thread's default allocator.
///
/// `std.heap.page_allocator` leaves its context pointer undefined, so it must
/// never be compared through `ptr`; the vtable pointer is well defined for every
/// allocator and is distinct per allocator implementation.
fn isDefaultAllocator(allocator: std.mem.Allocator) bool {
    return allocator.vtable == defaultAllocator().vtable;
}

/// Same check for two allocators of the same implementation (the tagged test
/// allocators have a real context pointer).
fn isTaggedAllocator(allocator: std.mem.Allocator, tag: *TaggedAllocator) bool {
    return allocator.vtable == tag.allocator().vtable and allocator.ptr == tag.allocator().ptr;
}

const ThreadOutcome = struct {
    saw_own_allocator: bool = false,
    saw_own_default: bool = false,
    nested_restored: bool = false,
    restored_default: bool = false,
};

fn threadWorker(
    own: *TaggedAllocator,
    other: *TaggedAllocator,
    outcome: *ThreadOutcome,
) void {
    const own_allocator = own.allocator();

    // A fresh thread starts from the default allocator, not from any override
    // that another thread installed.
    outcome.saw_own_default = isDefaultAllocator(globalAllocator());

    var outer = ScopedOverride.enter(own_allocator);
    outcome.saw_own_allocator = isTaggedAllocator(capture(), own);

    // A nested override must restore the intermediate allocator.
    {
        var inner = ScopedOverride.enter(other.allocator());
        if (isTaggedAllocator(capture(), other)) {
            const buffer = capture().alloc(u8, 32) catch return;
            capture().free(buffer);
        }
        inner.exit();
    }
    outcome.nested_restored = isTaggedAllocator(capture(), own);

    // Memory allocated under the override is released by the same allocator.
    {
        const buffer = capture().alloc(u8, 128) catch return;
        capture().free(buffer);
    }

    outer.exit();
    outcome.restored_default = isDefaultAllocator(capture());
}

test "operation allocator overrides are thread local" {
    var first = TaggedAllocator{ .backing = std.heap.page_allocator };
    var second = TaggedAllocator{ .backing = std.heap.page_allocator };
    var first_outcome = ThreadOutcome{};
    var second_outcome = ThreadOutcome{};

    const first_thread = try std.Thread.spawn(.{}, threadWorker, .{ &first, &second, &first_outcome });
    const second_thread = try std.Thread.spawn(.{}, threadWorker, .{ &second, &first, &second_outcome });
    first_thread.join();
    second_thread.join();

    for ([_]ThreadOutcome{ first_outcome, second_outcome }) |outcome| {
        // Every thread saw the default allocator before its own override, its own
        // allocator inside the override, the intermediate allocator after the
        // nested scope, and the default again at the end.
        try std.testing.expect(outcome.saw_own_default);
        try std.testing.expect(outcome.saw_own_allocator);
        try std.testing.expect(outcome.nested_restored);
        try std.testing.expect(outcome.restored_default);
    }

    // Each allocator only ever saw its own thread's allocations: the other
    // thread's override never reached it.
    const first_counts = first.counts();
    const second_counts = second.counts();
    try std.testing.expectEqual(first_counts.allocations, first_counts.frees);
    try std.testing.expectEqual(second_counts.allocations, second_counts.frees);
    try std.testing.expect(first_counts.allocations > 0);
    try std.testing.expect(second_counts.allocations > 0);

    // The test thread still uses the default allocator.
    try std.testing.expect(isDefaultAllocator(globalAllocator()));
}

test "scoped overrides nest and restore" {
    var outer_tag = TaggedAllocator{ .backing = std.heap.page_allocator };
    var inner_tag = TaggedAllocator{ .backing = std.heap.page_allocator };
    try std.testing.expect(isDefaultAllocator(globalAllocator()));

    var outer = ScopedOverride.enter(outer_tag.allocator());
    try std.testing.expect(isTaggedAllocator(capture(), &outer_tag));

    var inner = ScopedOverride.enter(inner_tag.allocator());
    try std.testing.expect(isTaggedAllocator(capture(), &inner_tag));
    inner.exit();
    try std.testing.expect(isTaggedAllocator(capture(), &outer_tag));

    outer.exit();
    try std.testing.expect(isDefaultAllocator(globalAllocator()));
}

test "recorded allocator keeps provenance across an override exit" {
    var tag = TaggedAllocator{ .backing = std.heap.page_allocator };

    var scope = ScopedOverride.enter(tag.allocator());
    const recorded = capture();
    const buffer = try recorded.alloc(u8, 64);
    scope.exit();

    // The override is gone, but the recorded allocator still owns the buffer.
    try std.testing.expect(!isTaggedAllocator(capture(), &tag));
    recorded.free(buffer);

    const counts = tag.counts();
    try std.testing.expectEqual(@as(usize, 1), counts.allocations);
    try std.testing.expectEqual(@as(usize, 1), counts.frees);
}
