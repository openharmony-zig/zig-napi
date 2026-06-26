```zig
.{
    .name = "appname",
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"zig-napi" = .{
            .url = "https://github.com/openharmony-zig/zig-napi/archive/refs/tags/<GIT_TAG>.tar.gz",
            .hash = "HASH_GOES_HERE",
        },
    },
}
```
