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
    sleepForFiveSeconds();
    tsfn.Ok(.{ 1, 2 }, .NonBlocking);
}

fn execute_thread_safe_function_with_error(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) void {
    sleepForFiveSeconds();
    tsfn.Err(napi.Error.withReason("TSFN Error"), .NonBlocking);
}

pub fn call_thread_safe_function(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) void {
    _ = std.Thread.spawn(.{}, execute_thread_safe_function, .{tsfn}) catch @panic("Failed to spawn thread");
    _ = std.Thread.spawn(.{}, execute_thread_safe_function_with_error, .{tsfn}) catch @panic("Failed to spawn thread");
}
