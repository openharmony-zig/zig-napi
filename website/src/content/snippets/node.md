```zig
const addon = try napi_build.nodeAddonBuild(b, .{
    .name = "hello",
    .napi_module = napi,
    .node_api = .{
        .version = .v8,
        .experimental = false,
    },
    .root_module_options = .{
        .root_source_file = b.path("./src/hello.zig"),
        .target = target,
        .optimize = optimize,
    },
});
_ = addon;
```
