const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../napi/env.zig").Env;
const Object = @import("../napi/value.zig").Object;
const NapiError = @import("../napi/wrapper/error.zig");
const Napi = @import("../napi/util/napi.zig").Napi;
const Undefined = @import("../napi/value/undefined.zig").Undefined;
const options = @import("../napi/options.zig");

pub fn NODE_API_MODULE_WITH_INIT(
    comptime name: []const u8,
    comptime root: type,
    init: ?fn (env: Env, exports: Object) anyerror!?Object,
) void {
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

        fn inner_init(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
            const inner_env = Env.from_raw(env);
            // Module initialization runs inside the embedding frame; keep that
            // frame intact and do not leak initialization errors into it.
            const outer_frame = NapiError.ErrorFrame.save();
            NapiError.clearLastError();
            defer outer_frame.restore();

            const export_obj = Object.from_raw(env, exports);
            const undefined_value = Undefined.New(inner_env);

            inline for (root_infos.@"struct".fields) |field| {
                const value = Napi.to_napi_value(env, @field(root, field.name), field.name) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };

                export_obj.Set(field.name, value) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };
            }

            inline for (root_infos.@"struct".decls) |decl| {
                if (comptime std.mem.eql(u8, decl.name, "napi_allocator")) {
                    continue;
                }
                const origin_value = @field(root, decl.name);
                const value = Napi.to_napi_value(env, origin_value, decl.name) catch |err| {
                    reportInitFailure(inner_env, err);
                    return undefined_value.raw;
                };
                export_obj.Set(decl.name, value) catch |err| {
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
            return InitFn.inner_init(env, exports);
        }

        fn node_api_version() callconv(.c) i32 {
            return @intFromEnum(options.selectedNapiVersion());
        }
    };

    comptime {
        if (build_options.node_addon) {
            if (options.isWasmNodeAddon()) {
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
