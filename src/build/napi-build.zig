const std = @import("std");

fn getEnvVarOptional(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        }
        return err;
    };
}

fn cloneSharedOptions(option: std.Build.SharedLibraryOptions) std.Build.SharedLibraryOptions {
    return std.Build.SharedLibraryOptions{
        .code_model = option.code_model,
        .name = option.name,
        .pic = option.pic,
        .error_tracing = option.error_tracing,
        .root_source_file = option.root_source_file,
        .optimize = option.optimize,
        .target = option.target,
        .link_libc = option.link_libc,
        .max_rss = option.max_rss,
        .omit_frame_pointer = option.omit_frame_pointer,
        .sanitize_thread = option.sanitize_thread,
        .single_threaded = option.single_threaded,
        .strip = option.strip,
        .zig_lib_dir = option.zig_lib_dir,
        .win32_manifest = option.win32_manifest,
        .version = option.version,
        .use_llvm = option.use_llvm,
        .use_lld = option.use_lld,
        .unwind_tables = option.unwind_tables,
    };
}

pub fn resolveNdkPath(build: *std.Build) ![]const u8 {
    const allocator = build.allocator;

    var ndkRoot: ?[]const u8 = null;

    const home = try getEnvVarOptional(allocator, "OHOS_NDK_HOME");
    if (home) |v| {
        ndkRoot = try std.fs.path.join(allocator, &[_][]const u8{ v, "native" });
    } else {
        const ohos_sdk_native = try getEnvVarOptional(allocator, "ohos_sdk_native");
        if (ohos_sdk_native) |v| {
            ndkRoot = v;
        }
    }
    return ndkRoot orelse "";
}

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .ohos },
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .ohos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .ohos },
};

fn linkNapi(build: *std.Build, compile: *std.Build.Step.Compile, target: std.Target.Query) !void {
    const allocator = build.allocator;

    compile.linkSystemLibrary("ace_napi.z");
    compile.linkage = .dynamic;

    const rootPath = try resolveNdkPath(build);

    const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
    const libPath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "lib" });

    compile.addLibraryPath(.{ .cwd_relative = libPath });
    compile.addIncludePath(.{ .cwd_relative = includePath });

    const platform: []const u8 = switch (target.cpu_arch.?) {
        .aarch64 => "aarch64-linux-ohos",
        .arm => "arm-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        else => "",
    };

    if (platform.len > 0) {
        const platformIncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, platform });
        const platformLibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, platform });

        compile.addIncludePath(.{ .cwd_relative = platformIncludePath });
        compile.addLibraryPath(.{ .cwd_relative = platformLibPath });
    }
}

pub const NativeAddonBuildResult = struct {
    arm64: ?*std.Build.Step.Compile,
    arm: ?*std.Build.Step.Compile,
    x64: ?*std.Build.Step.Compile,
};

pub fn nativeAddonBuild(build: *std.Build, option: std.Build.SharedLibraryOptions) !NativeAddonBuildResult {
    const currentTarget = if (option.target) |target| target.result else build.graph.host.result;

    // Respect the target platform for command line.
    const buildTargets: []const []const u8 = switch (currentTarget.abi.isOpenHarmony()) {
        true => switch (currentTarget.cpu.arch) {
            .aarch64 => &[_][]const u8{"arm64"},
            .arm => &[_][]const u8{"arm"},
            .x86_64 => &[_][]const u8{"x64"},
            else => &[_][]const u8{ "arm64", "arm", "x64" },
        },
        false => &[_][]const u8{ "arm64", "arm", "x64" },
    };

    var arm64: ?*std.Build.Step.Compile = null;
    var arm: ?*std.Build.Step.Compile = null;
    var x64: ?*std.Build.Step.Compile = null;

    for (buildTargets) |value| {
        if (std.mem.eql(u8, value, "arm64")) {
            var arm64Option = cloneSharedOptions(option);
            arm64Option.target = build.resolveTargetQuery(targets[0]);
            arm64 = build.addSharedLibrary(arm64Option);

            try linkNapi(build, arm64.?, targets[0]);

            const arm64DistDir: []const u8 = build.dupePath("arm64-v8a");
            const arm64Step = build.addInstallArtifact(arm64.?, .{
                .dest_dir = .{
                    .override = .{
                        .custom = arm64DistDir,
                    },
                },
            });

            build.getInstallStep().dependOn(&arm64Step.step);
        } else if (std.mem.eql(u8, value, "arm")) {
            var armOption = cloneSharedOptions(option);
            armOption.target = build.resolveTargetQuery(targets[1]);
            arm = build.addSharedLibrary(armOption);
            try linkNapi(build, arm.?, targets[1]);

            const armDistDir: []const u8 = build.dupePath("armeabi-v7a");
            const armStep = build.addInstallArtifact(arm.?, .{
                .dest_dir = .{
                    .override = .{
                        .custom = armDistDir,
                    },
                },
            });

            build.getInstallStep().dependOn(&armStep.step);
        } else if (std.mem.eql(u8, value, "x64")) {
            var x64Option = cloneSharedOptions(option);
            x64Option.target = build.resolveTargetQuery(targets[2]);
            x64 = build.addSharedLibrary(x64Option);
            try linkNapi(build, x64.?, targets[2]);

            const x64DistDir: []const u8 = build.dupePath("x86_64");
            const x64Step = build.addInstallArtifact(x64.?, .{
                .dest_dir = .{
                    .override = .{
                        .custom = x64DistDir,
                    },
                },
            });

            build.getInstallStep().dependOn(&x64Step.step);
        }
    }

    return .{ .arm64 = arm64, .arm = arm, .x64 = x64 };
}
