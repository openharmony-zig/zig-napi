const std = @import("std");
const napi = @import("napi");

const DebugAllocator = std.heap.DebugAllocator(.{
    .stack_trace_frames = 0,
    .enable_memory_limit = true,
    .thread_safe = true,
});

var debug_allocator: DebugAllocator = .init;
var tracking = false;
var previous_allocator: ?std.mem.Allocator = null;

/// Query under the same lock as alloc/free: finalizers and task owners may
/// release memory from a different thread while JavaScript waits for cleanup.
pub fn leak_tracker_live_bytes() usize {
    std.Io.Threaded.mutexLock(&debug_allocator.mutex);
    defer std.Io.Threaded.mutexUnlock(&debug_allocator.mutex);
    return debug_allocator.total_requested_bytes;
}

pub fn leak_tracker_start() !void {
    if (tracking) return error.TrackingAlreadyStarted;
    // A failed/aborted scope can still have Promise or TSFN finalizers holding
    // this allocator. Never overwrite its metadata while those owners exist.
    if (leak_tracker_live_bytes() != 0) return error.PreviousTrackingScopeStillLive;
    _ = debug_allocator.deinit();
    debug_allocator = .init;

    previous_allocator = napi.globalAllocator();
    napi.setOperationAllocator(debug_allocator.allocator());
    tracking = true;
}

pub fn leak_tracker_finish() bool {
    restoreAllocator();

    // Detection must not destroy the allocator on failure. ArkVM may release
    // Promise capabilities only during a later GC or environment shutdown.
    std.Io.Threaded.mutexLock(&debug_allocator.mutex);
    const leaks = debug_allocator.detectLeaks();
    std.Io.Threaded.mutexUnlock(&debug_allocator.mutex);
    if (leaks != 0) return false;

    _ = debug_allocator.deinit();
    debug_allocator = .init;
    return true;
}

fn restoreAllocator() void {
    if (!tracking) return;

    if (previous_allocator) |allocator| {
        napi.setOperationAllocator(allocator);
    } else {
        napi.resetOperationAllocator();
    }
    previous_allocator = null;
    tracking = false;
}

pub fn leak_tracker_abort() void {
    restoreAllocator();
}

pub fn tracked_alloc_roundtrip(len: u32) bool {
    const allocator = napi.globalAllocator();
    const buf = allocator.alloc(u8, len) catch return false;
    defer allocator.free(buf);

    @memset(buf, 0xaa);
    return buf.len == len;
}
