const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const arkvm_test = b.option(bool, "arkvm-test", "Build host ArkVM test addon without device-only libraries") orelse false;

    const zig_napi = b.dependency("zig-napi", .{});

    const napi = zig_napi.module("napi");
    const build_options = b.addOptions();
    build_options.addOption(bool, "arkvm_test", arkvm_test);

    if (arkvm_test) {
        const arkvm_target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        });
        const arkvm_root = b.createModule(.{
            .root_source_file = b.path("./src/hello.zig"),
            .target = arkvm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "napi", .module = napi },
            },
            .link_libc = true,
        });
        arkvm_root.addOptions("build_options", build_options);

        const arkvm_lib = b.addLibrary(.{
            .name = "hello",
            .root_module = arkvm_root,
            .linkage = .dynamic,
            .use_llvm = true,
        });
        arkvm_lib.linker_allow_shlib_undefined = true;

        const arkvm_step = b.addInstallArtifact(arkvm_lib, .{
            .dest_dir = .{
                .override = .{
                    .custom = "arkvm-host",
                },
            },
        });
        b.getInstallStep().dependOn(&arkvm_step.step);

        const dts = try napi_build.generateTypeDefinition(b, .{
            .root_source_file = b.path("./src/hello.zig"),
            .output = b.path("index.d.ts"),
            .napi_module = napi,
            .options = build_options,
        });
        b.getInstallStep().dependOn(&dts.step);
        return;
    }

    const result = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });

    if (result.arm64) |arm64| {
        arm64.root_module.addImport("napi", napi);
        arm64.root_module.addOptions("build_options", build_options);
        if (!arkvm_test) {
            arm64.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }
    if (result.arm) |arm| {
        arm.root_module.addImport("napi", napi);
        arm.root_module.addOptions("build_options", build_options);
        if (!arkvm_test) {
            arm.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }
    if (result.x64) |x64| {
        x64.root_module.addImport("napi", napi);
        x64.root_module.addOptions("build_options", build_options);
        if (!arkvm_test) {
            x64.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }

    const dts = try napi_build.generateTypeDefinition(b, .{
        .root_source_file = b.path("./src/hello.zig"),
        .output = b.path("index.d.ts"),
        .napi_module = napi,
        .options = build_options,
    });
    b.getInstallStep().dependOn(&dts.step);
}
