const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

/// True when the shared page allocator state needs the module lock.
const page_allocator_needs_lock = builtin.target.cpu.arch.isWasm();

/// Serializes every access to the page allocator state of this module.
///
/// `std.heap.page_allocator` is `std.heap.BrkAllocator` on WebAssembly: the std
/// aliases it for targets that claim to be single threaded, and a threaded
/// WebAssembly target does not provide a page allocator at all. The break
/// allocator keeps its free lists, its break pointer and its next-free
/// addresses in one *global* with no synchronization - it assumes exclusive
/// access to the target.
///
/// emnapi executes `napi_async_work` on real threads while Zig still reports
/// the target as single threaded, so two threads reach that global at the same
/// time: concurrent allocations can hand out memory that is still live and
/// concurrent frees corrupt the free lists. The audit repro trapped inside
/// `Allocator.destroy` with "memory access out of bounds" because the corrupted
/// free list returned a block that a worker thread was still using.
///
/// One module-global lock protects the one global state. A lock per wrapper (a
/// counting allocator, a registry) would not: every user of the same allocator
/// has to serialize against every other user. `std.Thread.Mutex` is a no-op
/// when `builtin.single_threaded` is true, which is exactly the case here, so
/// this is an atomic spin lock.
const PageLock = struct {
    var mutex: std.atomic.Mutex = .unlocked;

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock() void {
        mutex.unlock();
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        lock();
        defer unlock();
        return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        lock();
        defer unlock();
        return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        lock();
        defer unlock();
        return std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        lock();
        defer unlock();
        std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

comptime {
    // The lock above exists for exactly one allocator. If the std ever selects a
    // different page allocator on WebAssembly, this check fails the build
    // instead of silently locking nothing.
    if (page_allocator_needs_lock) {
        if (!builtin.single_threaded) {
            @compileError("a threaded WebAssembly target has no BrkAllocator-based page allocator to lock");
        }
        if (std.heap.page_allocator.vtable != &std.heap.BrkAllocator.vtable) {
            @compileError("the WebAssembly page allocator changed: re-check whether it still needs the module lock");
        }
    }
}

/// The page allocator of this target, safe to call from every thread.
///
/// On native targets this is `std.heap.page_allocator` itself: no lock, no
/// wrapper, the fast path is untouched. On WebAssembly it is the same allocator
/// behind one module-global lock, because emnapi runs native work on real
/// threads while the std believes the target is single threaded.
///
/// Use it as the backing of a custom `napi_allocator` (and as the default):
/// a custom allocator that takes its pages from `std.heap.page_allocator`
/// directly brings back the shared, unsynchronized state this function
/// serializes - and a lock of its own would not help, because it would not be
/// the lock every other user of that state takes.
pub fn safePageAllocator() std.mem.Allocator {
    if (comptime page_allocator_needs_lock) {
        return .{ .ptr = undefined, .vtable = &PageLock.vtable };
    }
    return std.heap.page_allocator;
}

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
/// the same time (atomics, a lock, or a system allocator). A custom allocator
/// that takes its pages from `std.heap.page_allocator` is not: use
/// `safePageAllocator()` as its backing.
pub fn defaultAllocator() std.mem.Allocator {
    if (@hasDecl(root, "napi_allocator")) {
        const allocator = root.napi_allocator;
        if (@TypeOf(allocator) != std.mem.Allocator) {
            @compileError("root.napi_allocator must be a std.mem.Allocator");
        }
        return allocator;
    }

    return safePageAllocator();
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
