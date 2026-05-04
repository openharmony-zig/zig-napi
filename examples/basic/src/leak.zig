const std = @import("std");
const napi = @import("napi");

const DebugAllocator = std.heap.DebugAllocator(.{
    .stack_trace_frames = 0,
});

var debug_allocator: DebugAllocator = .init;
var tracking = false;

pub fn leak_tracker_start() void {
    if (tracking) {
        _ = debug_allocator.deinit();
        debug_allocator = .init;
    }

    napi.util_allocator.global_manager.set(debug_allocator.allocator());
    tracking = true;
}

pub fn leak_tracker_finish() bool {
    if (!tracking) {
        return true;
    }

    napi.util_allocator.global_manager.set(std.heap.page_allocator);
    tracking = false;

    const result = debug_allocator.deinit();
    debug_allocator = .init;
    return result == .ok;
}
