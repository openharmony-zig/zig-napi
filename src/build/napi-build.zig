const std = @import("std");

fn getEnvVarOptional(build: *std.Build, name: []const u8) ?[]const u8 {
    return build.graph.environ_map.get(name);
}

fn pathExists(build: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(build.graph.io, path, .{}) catch return false;
    return true;
}

fn findLibnodeDllInPathList(build: *std.Build, paths: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        if (pathExists(build, build.pathJoin(&.{ dir, "libnode.dll" }))) {
            return dir;
        }
    }
    return null;
}

fn requireWindowsGnuLibnodePath(build: *std.Build) []const u8 {
    if (getEnvVarOptional(build, "LIBNODE_PATH")) |libnode_path| {
        if (pathExists(build, libnode_path)) {
            if (pathExists(build, build.pathJoin(&.{ libnode_path, "libnode.dll" }))) {
                return libnode_path;
            }
            std.debug.panic("libnode.dll not found in {s}", .{libnode_path});
        }
    }

    if (getEnvVarOptional(build, "LIBPATH")) |paths| {
        if (findLibnodeDllInPathList(build, paths)) |libnode_path| {
            return libnode_path;
        }
    }

    if (getEnvVarOptional(build, "PATH")) |paths| {
        if (findLibnodeDllInPathList(build, paths)) |libnode_path| {
            return libnode_path;
        }
    }

    @panic("libnode.dll not found in any search path");
}

fn cloneLibraryOptionsInternal(build: *std.Build, option: anytype, target: std.Build.ResolvedTarget) std.Build.LibraryOptions {
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
        // Keep the linkage as dynamic.
        .linkage = .dynamic,
        .version = option.version,
        .max_rss = option.max_rss,
        .use_llvm = option.use_llvm,
        .use_lld = option.use_lld,
        .zig_lib_dir = option.zig_lib_dir,
        .win32_manifest = option.win32_manifest,
    };
}

pub fn cloneLibraryOptions(build: *std.Build, option: NativeAddonBuildOptionsWithModule, target: std.Build.ResolvedTarget) std.Build.LibraryOptions {
    return cloneLibraryOptionsInternal(build, option, target);
}

pub fn resolveNdkPath(build: *std.Build) ![]const u8 {
    if (getEnvVarOptional(build, "OHOS_NDK_HOME")) |home| {
        return build.pathJoin(&.{ home, "native" });
    }
    if (getEnvVarOptional(build, "ohos_sdk_native")) |native| {
        return native;
    }
    return "";
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

pub const NodeAddonBuildResult = *std.Build.Step.Compile;

pub const NapiVersion = enum(i32) {
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,
    v5 = 5,
    v6 = 6,
    v7 = 7,
    v8 = 8,
    v9 = 9,
    v10 = 10,
    experimental = std.math.maxInt(i32),
};

pub const NodeApiOptions = struct {
    version: NapiVersion = .v8,
    experimental: bool = false,

    fn effectiveVersion(self: NodeApiOptions) i32 {
        return if (self.experimental) @intFromEnum(NapiVersion.experimental) else @intFromEnum(self.version);
    }
};

fn nodePlatform(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        .freebsd => "freebsd",
        .ios => "ios",
        else => @tagName(target.os.tag),
    };
}

fn nodeArch(target: std.Target) []const u8 {
    return switch (target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        .arm => "arm",
        else => @tagName(target.cpu.arch),
    };
}

fn nodeAbi(target: std.Target) ?[]const u8 {
    return switch (target.os.tag) {
        .windows => switch (target.abi) {
            .msvc => "msvc",
            .gnu => "gnu",
            .none => null,
            else => @tagName(target.abi),
        },
        .linux => switch (target.abi) {
            .gnu => "gnu",
            .musl => "musl",
            .none => null,
            else => @tagName(target.abi),
        },
        else => null,
    };
}

pub fn nodePlatformArchAbi(build: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const platform = nodePlatform(target.result);
    const arch = nodeArch(target.result);
    if (nodeAbi(target.result)) |abi| {
        return build.fmt("{s}-{s}-{s}", .{ platform, arch, abi });
    }
    return build.fmt("{s}-{s}", .{ platform, arch });
}

pub fn nodeAddonFilename(build: *std.Build, name: []const u8, target: std.Build.ResolvedTarget) []const u8 {
    return build.fmt("{s}.{s}.node", .{ name, nodePlatformArchAbi(build, target) });
}

pub const NativeAddonBuildOptionsWithModule = struct {
    name: []const u8,
    napi_module: ?*std.Build.Module = null,
    node_api: NodeApiOptions = .{},
    root_module_options: std.Build.Module.CreateOptions,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?std.Build.LazyPath = null,
    win32_manifest: ?std.Build.LazyPath = null,
};

fn isDefaultNodeApiOptions(options: NodeApiOptions) bool {
    const default: NodeApiOptions = .{};
    return options.effectiveVersion() == default.effectiveVersion() and options.experimental == default.experimental;
}

fn addConfiguredNapiImport(
    build: *std.Build,
    root_module: *std.Build.Module,
    napi_module: ?*std.Build.Module,
    build_options_module: *std.Build.Module,
    comptime node_addon: bool,
) void {
    root_module.addImport("build_options", build_options_module);
    if (napi_module) |module| {
        root_module.addImport("napi", createConfiguredNapiModule(build, module, build_options_module, node_addon));
    }
}

pub const NodeAddonBuildOptionsWithModule = struct {
    name: []const u8,
    napi_module: *std.Build.Module,
    root_module_options: std.Build.Module.CreateOptions,
    node_api: NodeApiOptions = .{},
    /// Optional Windows import library override.
    /// MSVC follows napi-rs and does not require this by default. GNU follows
    /// napi-rs' `LIBNODE_PATH`/`LIBPATH`/`PATH` libnode.dll search.
    node_import_lib: ?std.Build.LazyPath = null,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?std.Build.LazyPath = null,
    win32_manifest: ?std.Build.LazyPath = null,
};

var cached_arkvm_test_build: ?*std.Build = null;
var cached_arkvm_test_value: bool = false;

fn isArkvmTestBuild(build: *std.Build) bool {
    if (cached_arkvm_test_build == build) return cached_arkvm_test_value;

    cached_arkvm_test_value = build.option(bool, "arkvm-test", "Build host ArkVM test addon without device-only libraries") orelse false;
    cached_arkvm_test_build = build;
    return cached_arkvm_test_value;
}

const AddonBuildOptionsConfig = struct {
    napi_tsgen: bool = false,
    node_addon: bool = false,
    node_api: NodeApiOptions = .{},
};

fn createAddonBuildOptions(build: *std.Build, config: AddonBuildOptionsConfig) *std.Build.Step.Options {
    const options = build.addOptions();
    options.addOption(bool, "napi_tsgen", config.napi_tsgen);
    options.addOption(bool, "node_addon", config.node_addon);
    options.addOption(i32, "napi_version", config.node_api.effectiveVersion());
    options.addOption(bool, "napi_experimental", config.node_api.experimental);
    return options;
}

fn createConfiguredNapiModule(
    build: *std.Build,
    napi_module: *std.Build.Module,
    build_options_module: *std.Build.Module,
    comptime node_addon: bool,
) *std.Build.Module {
    const package = napi_module.owner;
    const header_path = package.path("src/sys/ohos");

    const napi_sys = build.createModule(.{
        .root_source_file = package.path("src/sys/api.zig"),
    });
    const napi = build.createModule(.{
        .root_source_file = package.path("src/napi.zig"),
    });

    napi_sys.addImport("build_options", build_options_module);
    napi.addImport("napi-sys", napi_sys);
    napi.addImport("build_options", build_options_module);
    if (!node_addon) {
        napi.addIncludePath(header_path);
        napi_sys.addIncludePath(header_path);
    }

    return napi;
}

fn arkvmHostAddonBuild(build: *std.Build, option: NativeAddonBuildOptionsWithModule) *std.Build.Step.Compile {
    const target = build.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    var hostOption = cloneLibraryOptions(build, option, target);
    hostOption.use_llvm = true;

    const compile = build.addLibrary(hostOption);
    compile.linker_allow_shlib_undefined = true;
    compile.root_module.link_libc = true;
    const addon_build_options = createAddonBuildOptions(build, .{
        .node_api = option.node_api,
    });
    const build_options_module = addon_build_options.createModule();
    addConfiguredNapiImport(build, compile.root_module, option.napi_module, build_options_module, false);

    const installStep = build.addInstallArtifact(compile, .{
        .dest_dir = .{
            .override = .{
                .custom = "arkvm-host",
            },
        },
    });
    build.getInstallStep().dependOn(&installStep.step);

    return compile;
}

pub fn nodeAddonBuild(build: *std.Build, option: NodeAddonBuildOptionsWithModule) !NodeAddonBuildResult {
    const addon_build_options = createAddonBuildOptions(build, .{
        .node_addon = true,
        .node_api = option.node_api,
    });
    const target = option.root_module_options.target orelse build.graph.host;

    var nodeOption = cloneLibraryOptionsInternal(build, option, target);
    nodeOption.linkage = .dynamic;

    const compile = build.addLibrary(nodeOption);
    const build_options_module = addon_build_options.createModule();
    addConfiguredNapiImport(build, compile.root_module, option.napi_module, build_options_module, true);
    compile.linker_allow_shlib_undefined = true;
    if (target.result.os.tag == .windows) {
        if (option.node_import_lib) |node_import_lib| {
            compile.root_module.addObjectFile(node_import_lib);
        } else if (getEnvVarOptional(build, "NODE_LIB_FILE")) |node_lib_file| {
            compile.root_module.addObjectFile(.{ .cwd_relative = node_lib_file });
        } else if (getEnvVarOptional(build, "NODE_LIB_DIR")) |node_lib_dir| {
            compile.root_module.addLibraryPath(.{ .cwd_relative = node_lib_dir });
            compile.root_module.linkSystemLibrary("node", .{ .use_pkg_config = .no });
        } else if (target.result.abi == .gnu) {
            const libnode_path = requireWindowsGnuLibnodePath(build);
            compile.root_module.addLibraryPath(.{ .cwd_relative = libnode_path });
            compile.root_module.linkSystemLibrary("node", .{ .use_pkg_config = .no });
        }
    }

    const nodeDistDir = "node";
    const outputFilename = nodeAddonFilename(build, option.name, target);
    const installStep = build.addInstallArtifact(compile, .{
        .dest_dir = .{
            .override = .{
                .custom = nodeDistDir,
            },
        },
        .implib_dir = if (target.result.os.tag == .windows) .{
            .override = .{
                .custom = nodeDistDir,
            },
        } else .disabled,
        .dest_sub_path = outputFilename,
    });
    build.getInstallStep().dependOn(&installStep.step);

    return compile;
}

pub const TypeDefinitionBuildOptions = struct {
    root_source_file: std.Build.LazyPath,
    output: std.Build.LazyPath,
    napi_module: *std.Build.Module,
    node_api: NodeApiOptions = .{},
    // Optional text injected after the generated banner comments.
    header: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

pub fn generateTypeDefinition(build: *std.Build, option: TypeDefinitionBuildOptions) !*std.Build.Step.Run {
    _ = isArkvmTestBuild(build);

    const tsgen_build_options = createAddonBuildOptions(build, .{
        .napi_tsgen = true,
        .node_api = option.node_api,
    });

    const tsgen_napi_sys = build.addModule("zig-napi-tsgen-napi-sys", .{
        .root_source_file = option.napi_module.owner.path("src/sys/api.zig"),
    });
    const tsgen_napi = build.addModule("zig-napi-tsgen-napi", .{
        .root_source_file = option.napi_module.owner.path("src/napi.zig"),
    });
    const tsgen_build_options_module = tsgen_build_options.createModule();
    tsgen_napi_sys.addImport("build_options", tsgen_build_options_module);
    tsgen_napi.addImport("napi-sys", tsgen_napi_sys);
    tsgen_napi.addImport("build_options", tsgen_build_options_module);
    tsgen_napi.addIncludePath(option.napi_module.owner.path("src/sys/ohos"));
    tsgen_napi_sys.addIncludePath(option.napi_module.owner.path("src/sys/ohos"));

    const generator_root = build.createModule(.{
        .root_source_file = option.napi_module.owner.path("src/build/napi-tsgen.zig"),
        .target = build.graph.host,
    });

    const generator = build.addExecutable(.{
        .name = "zig-napi-tsgen",
        .root_module = generator_root,
    });

    const addon_root = build.createModule(.{
        .root_source_file = option.root_source_file,
        .target = build.graph.host,
        .imports = &.{
            .{
                .name = "napi",
                .module = tsgen_napi,
            },
        },
    });
    const addon_build_options = option.options orelse createAddonBuildOptions(build, .{
        .node_api = option.node_api,
    });
    addon_root.addImport("build_options", addon_build_options.createModule());

    const ndk_root = try resolveNdkPath(build);
    if (ndk_root.len > 0) {
        const include_path = try std.fs.path.join(build.allocator, &[_][]const u8{ ndk_root, "sysroot", "usr", "include" });
        addon_root.addIncludePath(.{ .cwd_relative = include_path });

        const platform_include_path = try std.fs.path.join(build.allocator, &[_][]const u8{
            ndk_root,
            "sysroot",
            "usr",
            "include",
            "aarch64-linux-ohos",
        });
        addon_root.addIncludePath(.{ .cwd_relative = platform_include_path });
    }

    generator.root_module.addImport("addon_root", addon_root);
    generator.root_module.addImport("napi", tsgen_napi);

    const run = build.addRunArtifact(generator);
    run.addFileArg(option.output);
    run.addFileArg(option.root_source_file);
    run.addArg(option.header orelse "");
    return run;
}

pub fn nativeAddonBuild(build: *std.Build, option: NativeAddonBuildOptionsWithModule) !NativeAddonBuildResult {
    if (option.napi_module == null and !isDefaultNodeApiOptions(option.node_api)) {
        std.debug.panic("nativeAddonBuild requires .napi_module when .node_api is configured so the napi wrapper sees the selected N-API version", .{});
    }

    const arkvm_test = isArkvmTestBuild(build);
    if (arkvm_test) {
        const host = arkvmHostAddonBuild(build, option);
        return .{ .arm64 = null, .arm = null, .x64 = host };
    }

    const addon_build_options = createAddonBuildOptions(build, .{
        .node_api = option.node_api,
    });
    const build_options_module = addon_build_options.createModule();

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
            addConfiguredNapiImport(build, arm64.?.root_module, option.napi_module, build_options_module, false);
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
            addConfiguredNapiImport(build, arm.?.root_module, option.napi_module, build_options_module, false);
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
            addConfiguredNapiImport(build, x64.?.root_module, option.napi_module, build_options_module, false);
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
