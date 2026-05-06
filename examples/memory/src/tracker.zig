const std = @import("std");
const napi = @import("napi");

const DebugAllocator = std.heap.DebugAllocator(.{
    .stack_trace_frames = 0,
});

var debug_allocator: DebugAllocator = .init;
var tracking = false;
var previous_allocator: ?std.mem.Allocator = null;

pub fn leak_tracker_start() void {
    if (tracking) {
        if (previous_allocator) |allocator| {
            napi.setOperationAllocator(allocator);
        } else {
            napi.resetOperationAllocator();
        }
        previous_allocator = null;
        tracking = false;
        _ = debug_allocator.deinit();
        debug_allocator = .init;
    }

    previous_allocator = napi.globalAllocator();
    napi.setOperationAllocator(debug_allocator.allocator());
    tracking = true;
}

pub fn leak_tracker_finish() bool {
    if (!tracking) {
        return true;
    }

    if (previous_allocator) |allocator| {
        napi.setOperationAllocator(allocator);
    } else {
        napi.resetOperationAllocator();
    }
    previous_allocator = null;
    tracking = false;

    const result = debug_allocator.deinit();
    debug_allocator = .init;
    return result == .ok;
}

pub fn leak_tracker_abort() void {
    if (!tracking) {
        return;
    }

    if (previous_allocator) |allocator| {
        napi.setOperationAllocator(allocator);
    } else {
        napi.resetOperationAllocator();
    }
    previous_allocator = null;
    tracking = false;
}

pub fn tracked_alloc_roundtrip(len: u32) bool {
    const allocator = napi.globalAllocator();
    const buf = allocator.alloc(u8, len) catch return false;
    defer allocator.free(buf);

    @memset(buf, 0xaa);
    return buf.len == len;
}
