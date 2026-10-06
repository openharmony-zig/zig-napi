const std = @import("std");
const builtin = @import("builtin");
var crash_flag: std.atomic.Value(i32) = .init(0);
fn mark() callconv(.c) void {
    crash_flag.store(1, .release);
}
fn address() callconv(.c) usize {
    return @intFromPtr(&crash_flag);
}
/// No locks, allocation or engine entry: safe even from a trapped worker.
pub fn check() void {
    if (comptime builtin.cpu.arch.isWasm()) {
        if (crash_flag.load(.acquire) != 0) @trap();
    }
}
pub fn exportHooks() void {
    if (comptime builtin.cpu.arch.isWasm()) {
        @export(&mark, .{ .name = "napi_wasm_thread_crashed", .linkage = .strong });
        @export(&address, .{ .name = "napi_wasm_thread_crash_flag_address", .linkage = .strong });
    }
}
