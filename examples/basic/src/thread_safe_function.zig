const std = @import("std");
const napi = @import("napi");

const Args = struct { i32, i32 };
const Return = i32;

fn execute_thread_safe_function(f: *const f32) void {
    std.debug.print("f: {}\n", .{f.*});
    std.Thread.sleep(5_000_000_000);
    // tsfn.Ok(.{ 1, 2 }, .Blocking);
}

pub fn call_thread_safe_function(tsfn: *napi.ThreadSafeFunction(Args, Return, true, 0)) void {
    tsfn.Ok(.{ 1, 2 }, .Blocking);
    const f: f32 = 1.0;
    _ = std.Thread.spawn(.{}, execute_thread_safe_function, .{&f}) catch @panic("Failed to spawn thread");
}
