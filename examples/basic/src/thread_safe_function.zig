const std = @import("std");
const napi = @import("napi");

const Args = struct { i32, i32 };
const Return = i32;

fn sleepForFiveSeconds() void {
    var req = std.c.timespec{
        .sec = 5,
        .nsec = 0,
    };
    _ = std.c.nanosleep(&req, null);
}

fn execute_thread_safe_function(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) void {
    defer tsfn.release(.Release) catch {};
    sleepForFiveSeconds();
    tsfn.Ok(.{ 1, 2 }, .NonBlocking) catch {};
}

fn execute_thread_safe_function_with_error(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) void {
    defer tsfn.release(.Release) catch {};
    sleepForFiveSeconds();
    tsfn.Err(napi.Error.withReason("TSFN Error"), .NonBlocking) catch {};
}

pub fn call_thread_safe_function(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) !void {
    try tsfn.acquire();
    const worker = try std.Thread.spawn(.{}, execute_thread_safe_function, .{tsfn});
    worker.detach();

    try tsfn.acquire();
    const worker_with_error = try std.Thread.spawn(.{}, execute_thread_safe_function_with_error, .{tsfn});
    worker_with_error.detach();

    try tsfn.release(.Release);
}
