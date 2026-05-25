const std = @import("std");
const napi = @import("napi");

const TsfnArgs = struct { i32, i32 };
const TsfnReturn = i32;

fn executeThreadSafeFunction(tsfn: *napi.ThreadSafeFunction(TsfnArgs, TsfnReturn, true, 0)) void {
    defer tsfn.release(.Release) catch {};
    tsfn.Ok(.{ 1, 2 }, .NonBlocking) catch {};
}

pub fn callThreadsafeFunction(tsfn: *napi.ThreadSafeFunction(TsfnArgs, TsfnReturn, true, 0)) !void {
    try tsfn.acquire();
    const worker = try std.Thread.spawn(.{}, executeThreadSafeFunction, .{tsfn});
    worker.detach();

    try tsfn.release(.Release);
}
