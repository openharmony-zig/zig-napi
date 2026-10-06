const std = @import("std");
const builtin = @import("builtin");
var retained = std.atomic.Value(bool).init(false);

/// Async cleanup can outlive a Node Worker environment. Keep the image mapped
/// until process exit so detached producers and finalizers retain valid code.
/// Loader failures are best effort, matching napi-rs' retention policy.
pub fn retain() void {
    if (comptime builtin.cpu.arch.isWasm()) return;
    if (retained.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    if (comptime builtin.os.tag == .windows) {
        const Win = struct {
            extern "kernel32" fn GetModuleHandleExW(u32, ?[*]const u16, *?*anyopaque) callconv(.winapi) i32;
        };
        var handle: ?*anyopaque = null;
        _ = Win.GetModuleHandleExW(1 | 4, @ptrCast(&retain), &handle);
    } else if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        const Loader = struct {
            const Info = extern struct { filename: ?[*:0]const u8, base: ?*anyopaque, symbol: ?[*:0]const u8, address: ?*anyopaque };
            extern "c" fn dladdr(*const anyopaque, *Info) c_int;
            extern "c" fn dlopen([*:0]const u8, c_int) ?*anyopaque;
        };
        var info: Loader.Info = std.mem.zeroes(Loader.Info);
        if (Loader.dladdr(@ptrCast(&retain), &info) == 0) return;
        const filename = info.filename orelse return;
        const no_load: c_int = if (builtin.os.tag == .macos) 0x10 else 4;
        _ = Loader.dlopen(filename, 1 | no_load);
    }
}
