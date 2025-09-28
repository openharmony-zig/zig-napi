const std = @import("std");

fn getEnvVarOptional(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        }
        return err;
    };
}

pub fn cloneLibraryOptions(build: *std.Build, option: NativeAddonBuildOptionsWithModule, target: std.Build.ResolvedTarget) std.Build.LibraryOptions {
    const root_module = build.createModule(.{
        .root_source_file = option.root_module_options.root_source_file,
        .target = target,
        .optimize = option.root_module_options.optimize,
        .imports = option.root_module_options.imports,
        .link_libc = option.root_module_options.link_libc,
        .link_libcpp = option.root_module_options.link_libcpp,
        .single_threaded = option.root_module_options.single_threaded,
        .strip = option.root_module_options.strip,
        .unwind_tables = option.root_module_options.unwind_tables,
        .dwarf_format = option.root_module_options.dwarf_format,
        .code_model = option.root_module_options.code_model,
        .stack_protector = option.root_module_options.stack_protector,
        .stack_check = option.root_module_options.stack_check,
        .sanitize_c = option.root_module_options.sanitize_c,
        .sanitize_thread = option.root_module_options.sanitize_thread,
        .fuzz = option.root_module_options.fuzz,
        .valgrind = option.root_module_options.valgrind,
        .pic = option.root_module_options.pic,
        .red_zone = option.root_module_options.red_zone,
        .omit_frame_pointer = option.root_module_options.omit_frame_pointer,
        .error_tracing = option.root_module_options.error_tracing,
        .no_builtin = option.root_module_options.no_builtin,
    });
    return std.Build.LibraryOptions{
        .name = option.name,
        .root_module = root_module,
        // Keep the linkage as dynami
        .linkage = .dynamic,
        .version = option.version,
        .max_rss = option.max_rss,
        .use_llvm = option.use_llvm,
        .use_lld = option.use_lld,
        .zig_lib_dir = option.zig_lib_dir,
        .win32_manifest = option.win32_manifest,
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
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .ohoseabi },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .ohos },
};

fn linkNapi(build: *std.Build, compile: *std.Build.Step.Compile, target: std.Target.Query) !void {
    const allocator = build.allocator;

    compile.root_module.linkSystemLibrary("ace_napi.z", .{});
    compile.linkage = .dynamic;

    compile.root_module.link_libc = true;

    const rootPath = try resolveNdkPath(build);

    const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
    const libPath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "lib" });

    compile.root_module.addLibraryPath(.{ .cwd_relative = libPath });
    compile.root_module.addIncludePath(.{ .cwd_relative = includePath });

    const platform: []const u8 = switch (target.cpu_arch.?) {
        .aarch64 => "aarch64-linux-ohos",
        .arm => "arm-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        else => "",
    };

    if (platform.len > 0) {
        const platformIncludePath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, platform });
        const platformLibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, platform });

        compile.root_module.addIncludePath(.{ .cwd_relative = platformIncludePath });
        compile.root_module.addLibraryPath(.{ .cwd_relative = platformLibPath });
    }
}

pub const NativeAddonBuildResult = struct {
    arm64: ?*std.Build.Step.Compile,
    arm: ?*std.Build.Step.Compile,
    x64: ?*std.Build.Step.Compile,
};

pub const NativeAddonBuildOptionsWithModule = struct {
    name: []const u8,
    root_module_options: std.Build.Module.CreateOptions,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?std.Build.LazyPath = null,
    win32_manifest: ?std.Build.LazyPath = null,
};

pub fn nativeAddonBuild(build: *std.Build, option: NativeAddonBuildOptionsWithModule) !NativeAddonBuildResult {
    const currentTarget = if (option.root_module_options.target) |target| target.result else build.graph.host.result;

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
            const target = build.resolveTargetQuery(targets[0]);

            const arm64Option = cloneLibraryOptions(build, option, target);
            arm64 = build.addLibrary(arm64Option);
            try linkNapi(build, arm64.?, target.query);

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
            const target = build.resolveTargetQuery(targets[1]);
            const armOption = cloneLibraryOptions(build, option, target);
            arm = build.addLibrary(armOption);
            try linkNapi(build, arm.?, target.query);

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
            const target = build.resolveTargetQuery(targets[2]);
            var x64Option = cloneLibraryOptions(build, option, target);
            // TODO: https://github.com/ziglang/zig/issues/25335
            x64Option.use_llvm = true;
            x64 = build.addLibrary(x64Option);
            try linkNapi(build, x64.?, target.query);

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
