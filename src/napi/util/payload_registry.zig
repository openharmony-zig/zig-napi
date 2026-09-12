const std = @import("std");

/// Proves a native wrap pointer belongs to this addon before dereferencing it.
/// A magic number inside untrusted `napi_unwrap` data is not such a proof: the
/// other addon may have wrapped a one-byte allocation or an opaque sentinel.
pub fn PayloadRegistry(comptime T: type) type {
    return struct {
        var mutex: std.atomic.Mutex = .unlocked;
        var pointers: std.AutoHashMapUnmanaged(usize, void) = .empty;

        fn lock() void {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
        }

        pub fn add(pointer: *T) !void {
            lock();
            defer mutex.unlock();
            try pointers.put(std.heap.page_allocator, @intFromPtr(pointer), {});
        }

        pub fn contains(pointer: *anyopaque) bool {
            lock();
            defer mutex.unlock();
            return pointers.contains(@intFromPtr(pointer));
        }

        pub fn remove(pointer: *T) void {
            lock();
            defer mutex.unlock();
            _ = pointers.remove(@intFromPtr(pointer));
            if (pointers.count() == 0) {
                pointers.deinit(std.heap.page_allocator);
                pointers = .empty;
            }
        }
    };
}

test "untrusted native pointers are checked without reading their memory" {
    const Registry = PayloadRegistry(u64);
    var value: u64 = 42;
    try std.testing.expect(!Registry.contains(@ptrFromInt(1)));
    try Registry.add(&value);
    try std.testing.expect(Registry.contains(&value));
    Registry.remove(&value);
    try std.testing.expect(!Registry.contains(&value));
}
