const std = @import("std");
const builtin = @import("builtin");
const napi = @import("napi");

const TsfnArgs = struct { i32, i32 };
const TsfnReturn = i32;
const Tsfn = napi.ThreadSafeFunction(TsfnArgs, TsfnReturn, true, 0);
const use_wasm_async_work = builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;

fn executeThreadSafeFunction(tsfn: *Tsfn) void {
    defer tsfn.release(.Release) catch {};
    tsfn.Ok(.{ 1, 2 }, .NonBlocking) catch {};
}

fn queueThreadSafeFunction(tsfn: *Tsfn) void {
    const worker = napi.Worker(napi.Env.from_raw(tsfn.env), .{
        .data = tsfn,
        .Execute = executeThreadSafeFunction,
    });
    worker.Queue();
}

pub fn callThreadsafeFunction(tsfn: *Tsfn) !void {
    try tsfn.acquire();
    errdefer tsfn.release(.Release) catch {};
    if (comptime use_wasm_async_work) {
        queueThreadSafeFunction(tsfn);
        return;
    }

    const worker = try std.Thread.spawn(.{}, executeThreadSafeFunction, .{tsfn});
    worker.detach();
}
