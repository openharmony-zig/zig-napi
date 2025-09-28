const log = @cImport({
    @cInclude("hilog/log.h");
});

pub fn info(msg: []const u8) void {
    _ = log.OH_LOG_Print(log.LOG_APP, log.LOG_INFO, 0x00, "napi", @ptrCast(msg.ptr));
}

pub fn test_hilog() void {
    info("test_hilog");
}
