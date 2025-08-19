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

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .ohos },
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .ohos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .ohos },
};

pub fn linkNapi(module: *std.Build.Module) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    if (ndkRoot) |rootPath| {
        const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
        const libPath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "lib" });

        module.addLibraryPath(.{ .cwd_relative = libPath });
        module.addIncludePath(.{ .cwd_relative = includePath });

        const arm64IncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "aarch64-linux-ohos" });
        const arm64LibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, "aarch64-linux-ohos" });

        module.addIncludePath(.{ .cwd_relative = arm64IncludePath });
        module.addLibraryPath(.{ .cwd_relative = arm64LibPath });
    } else {
        @panic("Environment OHOS_NDK_HOME or ohos_sdk_native not found, please set it as first.");
    }
}

pub fn nativeAddonBuild(build: *std.Build, option: std.Build.SharedLibraryOptions) !std.meta.Tuple(&.{ *std.Build.Step.Compile, *std.Build.Step.Compile, *std.Build.Step.Compile }) {
    var arm64Option = cloneSharedOptions(option);
    arm64Option.target = build.resolveTargetQuery(targets[0]);

    var armOption = cloneSharedOptions(option);
    armOption.target = build.resolveTargetQuery(targets[1]);

    var x64Option = cloneSharedOptions(option);
    x64Option.target = build.resolveTargetQuery(targets[2]);

    const arm64 = build.addSharedLibrary(arm64Option);
    const arm = build.addSharedLibrary(armOption);
    const x64 = build.addSharedLibrary(x64Option);

    // link N-API
    arm64.linkSystemLibrary("ace_napi.z");
    arm.linkSystemLibrary("ace_napi.z");
    x64.linkSystemLibrary("ace_napi.z");

    arm64.linkage = .dynamic;
    arm.linkage = .dynamic;
    x64.linkage = .dynamic;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    if (ndkRoot) |rootPath| {
        const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
        const libPath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "lib" });

        arm64.addLibraryPath(.{ .cwd_relative = libPath });
        arm.addLibraryPath(.{ .cwd_relative = libPath });
        x64.addLibraryPath(.{ .cwd_relative = libPath });

        arm64.addIncludePath(.{ .cwd_relative = includePath });
        arm.addIncludePath(.{ .cwd_relative = includePath });
        x64.addIncludePath(.{ .cwd_relative = includePath });

        const arm64IncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "aarch64-linux-ohos" });
        const armIncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "arm-linux-ohos" });
        const x64IncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "x86_64-linux-ohos" });

        const arm64LibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, "aarch64-linux-ohos" });
        const armLibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, "arm-linux-ohos" });
        const x64LibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, "x86_64-linux-ohos" });

        arm64.addLibraryPath(.{ .cwd_relative = arm64LibPath });
        arm.addLibraryPath(.{ .cwd_relative = armLibPath });
        x64.addLibraryPath(.{ .cwd_relative = x64LibPath });

        arm64.addIncludePath(.{ .cwd_relative = arm64IncludePath });
        arm.addIncludePath(.{ .cwd_relative = armIncludePath });
        x64.addIncludePath(.{ .cwd_relative = x64IncludePath });

        const arm64DistDir: []const u8 = build.dupePath("dist/arm64-v8a");
        const armDistDir: []const u8 = build.dupePath("dist/armeabi-v7a");
        const x64DistDir: []const u8 = build.dupePath("dist/x86_64");

        const arm64Step = build.addInstallArtifact(arm64, .{
            .dest_dir = .{
                .override = .{
                    .custom = arm64DistDir,
                },
            },
        });
        const armStep = build.addInstallArtifact(arm, .{
            .dest_dir = .{
                .override = .{
                    .custom = armDistDir,
                },
            },
        });
        const x64Step = build.addInstallArtifact(x64, .{
            .dest_dir = .{
                .override = .{
                    .custom = x64DistDir,
                },
            },
        });

        build.getInstallStep().dependOn(&arm64Step.step);
        build.getInstallStep().dependOn(&armStep.step);
        build.getInstallStep().dependOn(&x64Step.step);

        return .{ arm64, arm, x64 };
    } else {
        @panic("Environment OHOS_NDK_HOME or ohos_sdk_native not found, please set it as first.");
    }
}
