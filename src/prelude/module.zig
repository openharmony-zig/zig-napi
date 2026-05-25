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
        fn inner_init(env: napi.napi_env, exports: napi.napi_value) callconv(.c) napi.napi_value {
            const export_obj = Object.from_raw(env, exports);
            const undefined_value = Undefined.New(Env.from_raw(env));

            inline for (root_infos.@"struct".fields) |field| {
                const value = Napi.to_napi_value(env, @field(root, field.name), field.name) catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(Env.from_raw(env));
                    }
                    return undefined_value.raw;
                };

                export_obj.Set(field.name, value) catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(Env.from_raw(env));
                    }
                };
            }

            inline for (root_infos.@"struct".decls) |decl| {
                if (comptime std.mem.eql(u8, decl.name, "napi_allocator")) {
                    continue;
                }
                const origin_value = @field(root, decl.name);
                const value = Napi.to_napi_value(env, origin_value, decl.name) catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(Env.from_raw(env));
                    }
                    return undefined_value.raw;
                };
                export_obj.Set(decl.name, value) catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(Env.from_raw(env));
                    }
                };
            }

            if (init) |init_fn| {
                const result = init_fn(
                    Env.from_raw(env),
                    export_obj,
                ) catch |e| {
                    switch (e) {
                        error.GenericFailure, error.PendingException, error.Cancelled, error.EscapeCalledTwice, error.HandleScopeMismatch, error.CallbackScopeMismatch, error.QueueFull, error.Closing, error.BigintExpected, error.DateExpected, error.ArrayBufferExpected, error.DetachableArraybufferExpected, error.WouldDeadlock, error.NoExternalBuffersAllowed, error.Unknown, error.InvalidArg, error.ObjectExpected, error.StringExpected, error.NameExpected, error.FunctionExpected, error.NumberExpected, error.BooleanExpected, error.ArrayExpected => {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(env));
                            }
                        },
                        else => {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(env));
                            }
                        },
                    }
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
            return InitFn.inner_init(env, exports);
        }

        fn node_api_version() callconv(.c) i32 {
            return @intFromEnum(options.selectedNapiVersion());
        }
    };

    comptime {
        if (build_options.node_addon) {
            @export(&ModuleImpl.node_init, .{ .linkage = .strong, .name = "napi_register_module_v1" });
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
