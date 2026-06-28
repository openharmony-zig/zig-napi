```zig
const dts = try napi_build.generateTypeDefinition(b, .{
    .root_source_file = b.path("./src/hello.zig"),
    .output = b.path("index.d.ts"),
    .napi_module = napi,
});
b.getInstallStep().dependOn(&dts.step);
```
