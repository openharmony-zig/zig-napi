// OH_LOG_Print's C ABI from hilog/log.h. Keep this small binding independent
// of SDK header translation so the host declaration generator can import it.
extern "hilog_ndk.z" fn OH_LOG_Print(log_type: c_uint, level: c_uint, domain: c_uint, tag: [*:0]const u8, format: [*:0]const u8, ...) c_int;
const LOG_APP: c_uint = 0;
const LOG_INFO: c_uint = 4;

pub fn info(msg: []const u8) void {
    _ = OH_LOG_Print(LOG_APP, LOG_INFO, 0x00, "napi", "%{public}.*s", @as(c_int, @intCast(msg.len)), msg.ptr);
}

pub fn test_hilog() void {
    info("test_hilog");
}
