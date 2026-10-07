const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../napi/env.zig").Env;
const Object = @import("../napi/value.zig").Object;
const NapiError = @import("../napi/wrapper/error.zig");
const Napi = @import("../napi/util/napi.zig").Napi;
const Undefined = @import("../napi/value/undefined.zig").Undefined;
const Metadata = @import("../napi/metadata.zig");
const options = @import("../napi/options.zig");

pub fn NODE_API_MODULE_WITH_INIT(
    comptime name: []const u8,
    comptime root: type,
    init: ?fn (env: Env, exports: Object) anyerror!?Object,
) void {
    @setEvalBranchQuota(1_000_000);
    if (@hasDecl(build_options, "napi_tsgen") and build_options.napi_tsgen) {
        return;
    }

    const root_infos = @typeInfo(root);

    if (root_infos != .@"struct") {
        @compileError("NODE_API_MODULE only support struct type as root");
    }

    const InitFn = struct {
        /// Report a failed export conversion to JavaScript. A pending exception is
        /// left untouched so the original error object survives.
        fn reportInitFailure(inner_env: Env, err: anyerror) void {
            if (err == error.PendingException or NapiError.hasPendingException()) {
                return;
            }
            NapiError.throwCurrent(inner_env);
        }

        fn defineExport(exports: Object, comptime member: []const u8, value: napi.napi_value) !void {
            const config = comptime Metadata.get(root, member);
            var destination = exports;
            if (comptime config.namespace) |namespace| {
                if (try exports.HasOwn(namespace)) {
                    destination = try exports.Get(namespace, Object);
                } else {
                    destination = try Object.Create(Env.from_raw(exports.env));
                    try exports.Define(namespace, destination);
                }
            }
            const attributes: napi.napi_property_attributes = config.attributes orelse if (config.readonly)
                napi.napi_enumerable | napi.napi_configurable
            else
                napi.napi_default_jsproperty;
            try destination.DefineProperty(Metadata.name(root, member), value, attributes);
        }

        fn inner_init(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
            @setEvalBranchQuota(1_000_000);
            @import("retain_module.zig").retain();
            const inner_env = Env.from_raw(env);
            // Module initialization runs inside the embedding frame; keep that
            // frame intact and do not leak initialization errors into it.
            const outer_frame = NapiError.ErrorFrame.save();
            NapiError.clearLastError();
            defer outer_frame.restore();

            const export_obj = Object.from_raw(env, exports);
            const undefined_value = Undefined.New(inner_env);

            inline for (root_infos.@"struct".field_names) |field_name| {
                if (comptime Metadata.get(root, field_name).skip) continue;
                const value = Napi.to_napi_value(env, @field(root, field_name), Metadata.name(root, field_name)) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };

                defineExport(export_obj, field_name, value) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };
            }

            inline for (root_infos.@"struct".decl_names) |decl| {
                if (comptime Metadata.reserved(decl) or Metadata.get(root, decl).skip) {
                    continue;
                }
                const origin_value = @field(root, decl);
                if (comptime @TypeOf(origin_value) == type) {
                    // Object schemas/type aliases produce declarations only.
                    // Enum objects and class constructors have runtime exports.
                    if (comptime @typeInfo(origin_value) != .@"enum" and !@import("../napi/wrapper/class.zig").isClass(origin_value)) continue;
                }
                const value = Napi.to_napi_value(env, origin_value, Metadata.name(root, decl)) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };
                defineExport(export_obj, decl, value) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };
            }

            if (init) |init_fn| {
                const result = init_fn(
                    inner_env,
                    export_obj,
                ) catch |e| {
                    reportInitFailure(inner_env, e);
                    return export_obj.raw;
                };

                return (result orelse export_obj).raw;
            } else {
                return export_obj.raw;
            }
        }
    };

    const ModuleImpl = struct {
        const module = napi.napi_module{
            .nm_version = 1,
            .nm_flags = 0,
            .nm_filename = null,
            .nm_register_func = InitFn.inner_init,
            .nm_modname = @ptrCast(name.ptr),
            .nm_priv = null,
            .reserved = .{ null, null, null, null },
        };

        fn module_init() callconv(.c) void {
            napi.napi_module_register(@constCast(&module));
        }

        fn node_init(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
            if (@hasDecl(napi, "setup")) {
                napi.setup();
            }
            // A new environment is registering this addon image: release the
            // latch a previous WASI pre-teardown barrier set. emnapi runs module
            // registration on the main thread only, so a worker thread sharing
            // the same linear memory can never reach this mid-disposal.
            if (comptime options.isWasmNodeAddon()) {
                @import("../napi/async.zig").onWasmModuleRegister();
            }
            return InitFn.inner_init(env, exports);
        }

        fn node_api_version() callconv(.c) i32 {
            return @backingInt(options.selectedNapiVersion());
        }
    };

    comptime {
        if (build_options.node_addon) {
            if (options.isWasmNodeAddon()) {
                @import("napi-sys").wasmCrash.exportHooks();
                @export(&ModuleImpl.node_init, .{ .linkage = .strong, .name = "napi_register_wasm_v1" });
            } else {
                @export(&ModuleImpl.node_init, .{ .linkage = .strong, .name = "napi_register_module_v1" });
            }
            @export(&ModuleImpl.node_api_version, .{ .linkage = .strong, .name = "node_api_module_get_api_version_v1" });
        } else if (builtin.object_format == .elf) {
            const InitFnPtr = *const fn () callconv(.c) void;
            const ElfInit = struct {
                export const init_array: [1]InitFnPtr linksection(".init_array") = .{&ModuleImpl.module_init};
            };
            _ = ElfInit;
        }
    }
}

/// This function is used to register a module without an init function.
pub fn NODE_API_MODULE(
    comptime name: []const u8,
    comptime root: type,
) void {
    NODE_API_MODULE_WITH_INIT(name, root, null);
}
