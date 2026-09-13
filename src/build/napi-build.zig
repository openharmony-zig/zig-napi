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

fn isWasiNodeAddonTarget(target: std.Target) bool {
    return target.cpu.arch == .wasm32 and target.os.tag == .wasi;
}

/// WASI addons are built in two threading flavors.
///
/// Zig 0.16 only knows the `wasm32-wasi` triple — `zig build -Dtarget=wasm32-wasip1`
/// fails with `unknown OS: 'wasip1'` — so both napi-rs flavors are passed as
/// `-Dtarget=wasm32-wasi` and the threaded one adds
/// `-Dcpu=baseline+atomics+bulk_memory+mutable_globals`. The `atomics` feature is
/// therefore the only signal that separates a shared memory (threaded) build
/// from a single-threaded one; never rely on the requested name.
pub const WasiFlavor = enum {
    single_threaded,
    threads,

    pub fn sharedMemory(self: WasiFlavor) bool {
        return self == .threads;
    }
};

pub fn wasiFlavor(target: std.Target) WasiFlavor {
    return if (std.Target.wasm.featureSetHas(target.cpu.features, .atomics))
        .threads
    else
        .single_threaded;
}

/// Directory of the emnapi archive set this build links.
const emnapi_wasi_archive_dir = "wasm32-wasip1";
/// The only emnapi v2 archive set that is compatible with a Zig-built addon.
///
/// `libemnapi-basic-napi-rs.a` leaves `napi_create_async_work` and the
/// thread-safe function API as host imports, which the `@emnapi/core` plugins
/// implement. The C threaded composition (`libemnapi-napi-rs-mt.a`) instead
/// calls wasi-libc pthreads and `__wasilibc_futex_wait_atomic_wait`, and Zig
/// 0.16 ships wasi thread stubs (`pthread_create` returns `EAGAIN`) with no
/// futex symbol, so linking it would fail or silently break every uv thread
/// pool queue. Threaded addons therefore link the same archive and get real
/// parallelism from the JavaScript worker pool (`asyncWorkPoolSize > 0`),
/// which is driven by the `emnapi_async_worker_create` /
/// `emnapi_async_worker_init` exports this module provides.
const emnapi_basic_archive = "libemnapi-basic-napi-rs.a";
/// Full C composition; usable only where the toolchain provides wasi pthreads.
/// Reachable through the explicit `emnapi_archive` setting.
const emnapi_threads_archive = "libemnapi-napi-rs-mt.a";
/// wasi-sdk >= 34 archives, built against the new wasi-libc futex ABI.
const emnapi_wasi_threads_archive_dir = "wasm32-wasip1-threads";
const emnapi_wasi_sdk_34_archive_dir = "wasm32-wasip1-threads-wasi-sdk-34";

/// emnapi release that introduced the v2 archive layout and the
/// `emnapi_create_env` / `emnapi_delete_env` exports.
const emnapi_min_version_string = "2.0.0-alpha.5";

/// Imported memory shape for WASI addons.
pub const WasiMemory = struct {
    /// Imported memory minimum in 64 KiB pages. `null` leaves the minimum to
    /// wasm-ld, which derives it from the linked image (data + stack). The
    /// loader decides how much memory to actually create, so a hardcoded
    /// minimum here silently makes every smaller loader configuration fail
    /// with `RangeError: WebAssembly.Memory(): could not allocate memory`.
    initial_pages: ?u32 = null,
    /// Imported memory maximum in 64 KiB pages. 65536 pages is 4 GiB, matching
    /// napi-rs' `--max-memory=4294967296`, and is required for shared memory.
    max_pages: u32 = 65536,
    /// Stack size in bytes. `null` keeps the toolchain default (16 MiB with
    /// Zig's wasi linker script).
    stack_size: ?u64 = null,
};

/// Resolved emnapi archive for a WASI addon build.
pub const WasiEmnapiArchive = struct {
    /// Path passed to the linker.
    path: []const u8,
    /// Directory that contained the archive.
    lib_dir: []const u8,
    archive_name: []const u8,
    /// `version` from the `emnapi` package that provides the archive, when it
    /// could be read.
    version: ?[]const u8,
};

const WasiEmnapiSettings = struct {
    /// Explicit archive directory (the one that holds `lib*.a`).
    link_dir: ?[]const u8 = null,
    /// Explicit archive file name or path.
    archive: ?[]const u8 = null,
};

/// Command line `-D` values, read once per `*std.Build`: `Build.option` panics
/// on a second declaration of the same name, and one project builds several
/// addons. A map, not a last-used slot: dependency packages have their own
/// `*Build` (`Build.createChildOnly`), so the same process can interleave
/// builds A → B → A and a single slot would redeclare A's options.
const WasiCommandLineOptions = struct {
    link_dir: ?[]const u8 = null,
    archive: ?[]const u8 = null,
    initial_memory_pages: ?u32 = null,
    max_memory_pages: ?u32 = null,
    stack_size: ?u64 = null,
};

var cached_wasi_options: std.AutoHashMapUnmanaged(*std.Build, WasiCommandLineOptions) = .empty;

fn wasiCommandLineOptions(build: *std.Build) WasiCommandLineOptions {
    const entry = cached_wasi_options.getOrPut(build.allocator, build) catch @panic("out of memory");
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .link_dir = build.option([]const u8, "emnapi-link-dir", "Directory that holds the emnapi archive to link for WASI targets"),
            .archive = build.option([]const u8, "emnapi-archive", "emnapi archive file name or path to link for WASI targets"),
            .initial_memory_pages = build.option(u32, "wasi-initial-memory-pages", "WASI imported memory minimum in 64 KiB pages (default: the linker minimum)"),
            .max_memory_pages = build.option(u32, "wasi-max-memory-pages", "WASI imported memory maximum in 64 KiB pages"),
            .stack_size = build.option(u64, "wasi-stack-size", "WASI module stack size in bytes"),
        };
    }
    return entry.value_ptr.*;
}

fn wasiEmnapiSettings(build: *std.Build, option: NodeAddonBuildOptionsWithModule) WasiEmnapiSettings {
    const command_line = wasiCommandLineOptions(build);
    return .{
        .link_dir = option.emnapi_link_dir orelse command_line.link_dir orelse getEnvVarOptional(build, "EMNAPI_LINK_DIR"),
        .archive = option.emnapi_archive orelse command_line.archive orelse getEnvVarOptional(build, "EMNAPI_ARCHIVE"),
    };
}

fn joinPath(build: *std.Build, parts: []const []const u8) []const u8 {
    return std.fs.path.join(build.allocator, parts) catch @panic("out of memory");
}

fn readFileIfExists(build: *std.Build, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(build.graph.io, path, build.allocator, .limited(64 * 1024)) catch null;
}

/// `emnapi` package directory for an `emnapi/lib` directory, when it exists.
fn emnapiPackageDir(lib_dir: []const u8, build: *std.Build) ?[]const u8 {
    const package_dir = std.fs.path.dirname(lib_dir) orelse return null;
    if (!pathExists(build, joinPath(build, &.{ package_dir, "package.json" }))) return null;
    return package_dir;
}

/// `version` field of an `emnapi` package manifest, reported in build errors.
fn readEmnapiVersion(build: *std.Build, package_dir: []const u8) ?[]const u8 {
    const manifest = readFileIfExists(build, joinPath(build, &.{ package_dir, "package.json" })) orelse return null;
    defer build.allocator.free(manifest);

    const parsed = std.json.parseFromSlice(std.json.Value, build.allocator, manifest, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const version = switch (object.get("version") orelse return null) {
        .string => |version| version,
        else => return null,
    };
    return build.allocator.dupe(u8, version) catch @panic("out of memory");
}

/// Candidate `emnapi/lib` directories, nearest first: the project the build
/// was invoked from, then every ancestor. npm and pnpm both hoist `emnapi` to
/// the workspace root, so a standalone `zig build` in a scaffolded addon and a
/// build inside this repository's test addon are covered by the same walk.
fn emnapiLibDirCandidates(build: *std.Build) []const []const u8 {
    var dirs = std.array_list.Managed([]const u8).init(build.allocator);
    var current: ?[]const u8 = build.build_root.path orelse ".";
    while (current) |dir| {
        dirs.append(joinPath(build, &.{ dir, "node_modules", "emnapi", "lib" })) catch @panic("out of memory");
        current = std.fs.path.dirname(dir);
    }
    return dirs.toOwnedSlice() catch @panic("out of memory");
}

/// Archive paths to try inside one `emnapi/lib` directory. `archive_name` is
/// the flavor's default archive; an explicitly requested name (for example
/// `libemnapi-napi-rs-mt.a`) is looked up in the threaded directories too.
fn wasiArchivePaths(
    build: *std.Build,
    lib_dir: []const u8,
    archive_name: []const u8,
    flavor: WasiFlavor,
) []const []const u8 {
    var paths = std.array_list.Managed([]const u8).init(build.allocator);
    paths.append(joinPath(build, &.{ lib_dir, emnapi_wasi_archive_dir, archive_name })) catch @panic("out of memory");
    if (flavor.sharedMemory()) {
        paths.append(joinPath(build, &.{ lib_dir, emnapi_wasi_threads_archive_dir, archive_name })) catch @panic("out of memory");
        paths.append(joinPath(build, &.{ lib_dir, emnapi_wasi_sdk_34_archive_dir, archive_name })) catch @panic("out of memory");
    }
    return paths.toOwnedSlice() catch @panic("out of memory");
}

fn resolveWasiEmnapiArchive(
    build: *std.Build,
    option: NodeAddonBuildOptionsWithModule,
    flavor: WasiFlavor,
) WasiEmnapiArchive {
    const settings = wasiEmnapiSettings(build, option);
    var searched = std.array_list.Managed([]const u8).init(build.allocator);
    var discovered_package_dir: ?[]const u8 = null;
    var discovered_version: ?[]const u8 = null;

    if (settings.archive) |archive| {
        // An absolute path, or one with a separator, is used as given; a bare
        // file name is resolved against the configured/discovered lib dirs.
        if (std.fs.path.isAbsolute(archive) or std.mem.indexOfAny(u8, archive, "/\\") != null) {
            if (pathExists(build, archive)) {
                return .{
                    .path = archive,
                    .lib_dir = std.fs.path.dirname(archive) orelse ".",
                    .archive_name = std.fs.path.basename(archive),
                    .version = null,
                };
            }
            std.debug.panic(
                "emnapi archive {s} does not exist; check .emnapi_archive, -Demnapi-archive or EMNAPI_ARCHIVE",
                .{archive},
            );
        }
    }

    const archive_name = settings.archive orelse emnapi_basic_archive;
    var lib_dirs = std.array_list.Managed([]const u8).init(build.allocator);
    if (settings.link_dir) |link_dir| {
        lib_dirs.append(link_dir) catch @panic("out of memory");
    } else {
        lib_dirs.appendSlice(emnapiLibDirCandidates(build)) catch @panic("out of memory");
    }

    for (lib_dirs.items) |lib_dir| {
        if (emnapiPackageDir(lib_dir, build)) |package_dir| {
            if (discovered_package_dir == null) {
                discovered_package_dir = package_dir;
                discovered_version = readEmnapiVersion(build, package_dir);
            }
        }
        for (wasiArchivePaths(build, lib_dir, archive_name, flavor)) |path| {
            if (pathExists(build, path)) {
                return .{
                    .path = path,
                    .lib_dir = std.fs.path.dirname(path) orelse lib_dir,
                    .archive_name = archive_name,
                    .version = if (emnapiPackageDir(lib_dir, build)) |package_dir| readEmnapiVersion(build, package_dir) else null,
                };
            }
            searched.append(path) catch @panic("out of memory");
        }
    }

    var message: std.Io.Writer.Allocating = .init(build.allocator);
    const writer = &message.writer;
    const flavor_name: []const u8 = if (flavor.sharedMemory()) "wasm32-wasip1-threads" else "wasm32-wasip1";
    writer.print(
        "emnapi archive for {s} was not found: expected {s} in " ++
            "<emnapi>/lib/{s}/. Searched:\n",
        .{ flavor_name, archive_name, emnapi_wasi_archive_dir },
    ) catch @panic("out of memory");
    for (searched.items) |path| writer.print("  {s}\n", .{path}) catch @panic("out of memory");
    if (discovered_package_dir) |package_dir| {
        writer.print("Found an emnapi package at {s}", .{package_dir}) catch @panic("out of memory");
        if (discovered_version) |version| {
            writer.print(" (version {s})", .{version}) catch @panic("out of memory");
        }
        writer.print(
            "\nemnapi v1 used a different archive layout; this build links the archives " ++
                "introduced in emnapi {s}, which leave async work and thread-safe functions " ++
                "to the host runtime.\n",
            .{emnapi_min_version_string},
        ) catch @panic("out of memory");
    } else if (settings.link_dir) |link_dir| {
        writer.print(
            "{s} was given as the archive directory but does not hold the archive; " ++
                "pass the directory that directly contains lib{s}.\n",
            .{ link_dir, archive_name },
        ) catch @panic("out of memory");
    } else {
        writer.print(
            "No node_modules/emnapi was found from {s} upwards; install the emnapi runtime " ++
                "next to the addon project.\n",
            .{build.build_root.path orelse "."},
        ) catch @panic("out of memory");
    }
    writer.print(
        "Install matching versions, for example:\n" ++
            "  npm install -D emnapi@{s} @emnapi/core@{s} @emnapi/runtime@{s}\n" ++
            "Or point the build at an existing archive directory:\n" ++
            "  zig build -Demnapi-link-dir=<dir> [-Demnapi-archive={s}]\n" ++
            "The full C threaded archive ({s}) needs wasi-libc pthreads and is only " ++
            "linkable by toolchains that provide them (not Zig 0.16).\n",
        .{
            emnapi_min_version_string,
            emnapi_min_version_string,
            emnapi_min_version_string,
            emnapi_threads_archive,
            emnapi_threads_archive,
        },
    ) catch @panic("out of memory");
    std.debug.panic("{s}", .{message.written()});
}

/// Imported memory shape for a WASI addon: programmatic defaults, overridden by
/// the command line options a consumer's `zig build` accepts, then validated.
fn wasiMemory(build: *std.Build, option: NodeAddonBuildOptionsWithModule) WasiMemory {
    const command_line = wasiCommandLineOptions(build);
    var memory = option.wasi_memory;
    if (command_line.initial_memory_pages) |pages| memory.initial_pages = pages;
    if (command_line.max_memory_pages) |pages| memory.max_pages = pages;
    if (command_line.stack_size) |size| memory.stack_size = size;
    validateWasiMemory(memory);
    return memory;
}

/// Rejects memory limits a Zig-built wasi addon cannot run with.
///
/// `WebAssembly.Memory` itself accepts `initial == maximum`, but a Zig wasi
/// module allocates through `sbrk`/`BrkAllocator`, which grows the linear
/// memory *above its current size*. With equal limits there is no headroom, so
/// every allocation after the linked image fails — including the emnapi
/// environment and the async work pool's worker blocks (measured: with
/// `initial == maximum == 520` pages, `malloc(1 MiB)` returns 0). Failing the
/// build beats emitting a loader that traps on the first environment or worker
/// allocation.
fn validateWasiMemory(memory: WasiMemory) void {
    if (memory.max_pages == 0 or memory.max_pages > 65536) {
        std.debug.panic(
            "WASI memory maximum must be between 1 and 65536 pages (4 GiB), got {d}; " ++
                "pass -Dwasi-max-memory-pages=<pages>",
            .{memory.max_pages},
        );
    }
    if (memory.initial_pages) |pages| {
        if (pages == 0) {
            std.debug.panic("WASI imported memory minimum must be at least 1 page, got 0", .{});
        }
        if (pages > memory.max_pages) {
            std.debug.panic(
                "WASI imported memory minimum ({d} pages) must not exceed the maximum ({d} pages)",
                .{ pages, memory.max_pages },
            );
        }
        if (pages == memory.max_pages) {
            std.debug.panic(
                "WASI imported memory minimum equals the maximum ({d} pages): Zig's wasi allocator " ++
                    "grows the linear memory above its current size, so the module would have no " ++
                    "headroom for the environment or the async work pool. Leave the minimum unset " ++
                    "(the linker minimum is used) or keep it below -Dwasi-max-memory-pages",
                .{pages},
            );
        }
    }
    if (memory.stack_size) |size| {
        if (size == 0) {
            std.debug.panic("WASI stack size must be greater than zero", .{});
        }
        if (memory.initial_pages) |pages| {
            const minimum_bytes = @as(u64, pages) * 65536;
            if (size >= minimum_bytes) {
                std.debug.panic(
                    "WASI stack size ({d} bytes) does not fit in the imported memory minimum " ++
                        "({d} pages = {d} bytes); raise -Dwasi-initial-memory-pages or lower " ++
                        "-Dwasi-stack-size",
                    .{ size, pages, minimum_bytes },
                );
            }
        }
    }
}

/// Symbols every WASI addon must export. `napi_register_wasm_v1` and
/// `node_api_module_get_api_version_v1` come from the Zig module prelude,
/// `emnapi_create_env` / `emnapi_delete_env` from the emnapi archive, and
/// `@emnapi/core` v2 calls the latter pair while initializing the native
/// environment (`_emnapi_create_env is not a function` otherwise).
const wasi_common_export_symbols = [_][]const u8{
    "malloc",
    "free",
    "napi_register_wasm_v1",
    "node_api_module_get_api_version_v1",
    "emnapi_create_env",
    "emnapi_delete_env",
};

/// Exports the `@emnapi/core` async work pool uses. emnapi's C implementations
/// live in the `emnapi-basic-mt` archive, which v2 no longer publishes for
/// WASI, so the module provides both: the block allocator in `src/sys/wasm.zig`
/// and the frameless worker entry point in
/// `src/sys/emnapi_async_worker_init.S`.
const wasi_threads_export_symbols = [_][]const u8{
    "emnapi_async_worker_create",
    "emnapi_async_worker_init",
};

/// Worker entry point that installs a pool worker's stack and TLS base. It has
/// to be assembly: it switches the `__stack_pointer` / `__tls_base` wasm
/// globals and must return without restoring them, so a compiler prologue and
/// epilogue would break the switch.
const emnapi_async_worker_init_asm = "src/sys/emnapi_async_worker_init.S";

/// Locked C allocator entry points for threaded addons.
///
/// Every worker instance allocates through the module's exported `malloc` and
/// `free`, and the allocator Zig's libc installs there (`BrkAllocator`, whose
/// free lists are a plain global) is not synchronized, because Zig only builds
/// single-threaded wasm. Two workers allocating at the same time therefore
/// corrupt the shared heap. This unit redefines the allocator entry points
/// around one shared spin lock; it has to be a separate object *without* libc,
/// because a strong definition inside the same Zig compilation unit as libc is
/// rejected as an exported-symbol collision. Zig's libc symbols are weak
/// precisely so that a regular object can override them.
///
/// Only the threaded flavor links it: a single-threaded addon has one thread, so
/// libc's allocator is already correct there and a second allocator instance
/// would only add risk.
const emnapi_alloc_source = "src/sys/emnapi_alloc.zig";

fn linkWasiEmnapi(
    build: *std.Build,
    compile: *std.Build.Step.Compile,
    option: NodeAddonBuildOptionsWithModule,
    flavor: WasiFlavor,
) void {
    const archive = resolveWasiEmnapiArchive(build, option, flavor);
    compile.root_module.addObjectFile(.{ .cwd_relative = archive.path });

    if (flavor.sharedMemory()) {
        // Both live in this package, not in the addon being built, so resolve
        // them through the napi module's owning package.
        compile.root_module.addAssemblyFile(option.napi_module.owner.path(emnapi_async_worker_init_asm));

        const alloc_object = build.addObject(.{
            .name = "emnapi-alloc",
            .root_module = build.createModule(.{
                .root_source_file = option.napi_module.owner.path(emnapi_alloc_source),
                .target = compile.root_module.resolved_target,
                .optimize = compile.root_module.optimize.?,
            }),
        });
        compile.root_module.addObjectFile(alloc_object.getEmittedBin());

        compile.root_module.export_symbol_names = &(wasi_common_export_symbols ++
            wasi_threads_export_symbols ++
            wasi_alloc_diagnostic_symbols);
    } else {
        compile.root_module.export_symbol_names = &wasi_common_export_symbols;
    }
}

/// Let a test prove the locked allocator is the one linked: libc's allocator
/// would leave these at zero while the plugins allocate.
const wasi_alloc_diagnostic_symbols = [_][]const u8{
    "__emnapi_alloc_entries",
    "__emnapi_alloc_spins",
};

/// napi-rs' `platformArchABI` for a target. WASI flavors use napi-rs' names
/// rather than the Zig triple: the threaded flavor is `wasm32-wasi` and the
/// single-threaded one is `wasm32-wasip1`, which is also the loader suffix
/// (`*.wasi.cjs` vs `*.wasip1.cjs`) the bindings are generated under.
pub fn nodePlatformArchAbi(build: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    if (isWasiNodeAddonTarget(target.result)) {
        return if (wasiFlavor(target.result).sharedMemory()) "wasm32-wasi" else "wasm32-wasip1";
    }

    const platform = nodePlatform(target.result);
    const arch = nodeArch(target.result);
    if (nodeAbi(target.result)) |abi| {
        return build.fmt("{s}-{s}-{s}", .{ platform, arch, abi });
    }
    return build.fmt("{s}-{s}", .{ platform, arch });
}

pub fn nodeAddonExtension(target: std.Build.ResolvedTarget) []const u8 {
    return if (isWasiNodeAddonTarget(target.result)) "wasm" else "node";
}

pub fn nodeAddonFilename(build: *std.Build, name: []const u8, target: std.Build.ResolvedTarget) []const u8 {
    return build.fmt("{s}.{s}.{s}", .{ name, nodePlatformArchAbi(build, target), nodeAddonExtension(target) });
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
    /// Explicit directory that holds the emnapi archive to link for WASI
    /// targets. Defaults to `-Demnapi-link-dir`, `EMNAPI_LINK_DIR`, and
    /// `node_modules/emnapi/lib` discovered upwards from the build root.
    emnapi_link_dir: ?[]const u8 = null,
    /// Explicit emnapi archive name or path for WASI targets. Defaults to
    /// `-Demnapi-archive`, `EMNAPI_ARCHIVE`, and the flavor's emnapi v2
    /// archive.
    emnapi_archive: ?[]const u8 = null,
    /// Imported memory and stack shape for WASI targets.
    wasi_memory: WasiMemory = .{},
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
    const is_wasi = isWasiNodeAddonTarget(target.result);

    var nodeOption = cloneLibraryOptionsInternal(build, option, target);
    nodeOption.linkage = .dynamic;

    const wasi_flavor = wasiFlavor(target.result);
    const compile = if (is_wasi) compile: {
        const memory = wasiMemory(build, option);
        const wasm = build.addExecutable(.{
            .name = nodeOption.name,
            .root_module = nodeOption.root_module,
            .version = nodeOption.version,
            .max_rss = nodeOption.max_rss,
            .use_llvm = nodeOption.use_llvm,
            .use_lld = nodeOption.use_lld,
            .zig_lib_dir = nodeOption.zig_lib_dir,
            .win32_manifest = nodeOption.win32_manifest,
        });
        wasm.entry = .disabled;
        wasm.import_symbols = true;
        wasm.import_memory = true;
        wasm.export_table = true;
        // Only a shared memory module may be handed to worker threads; a
        // single-threaded addon must stay unshared so that it also loads in
        // environments without cross-origin isolation.
        wasm.shared_memory = wasi_flavor.sharedMemory();
        if (memory.initial_pages) |pages| wasm.initial_memory = @as(u64, pages) * 65536;
        wasm.max_memory = @as(u64, memory.max_pages) * 65536;
        wasm.stack_size = memory.stack_size;
        break :compile wasm;
    } else build.addLibrary(nodeOption);
    const build_options_module = addon_build_options.createModule();
    addConfiguredNapiImport(build, compile.root_module, option.napi_module, build_options_module, true);
    compile.linker_allow_shlib_undefined = true;
    if (is_wasi) {
        compile.rdynamic = true;
        compile.root_module.link_libc = true;
        linkWasiEmnapi(build, compile, option, wasi_flavor);
    }
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
