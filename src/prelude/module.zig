const napi = @import("napi-sys").napi_sys;
const Env = @import("../napi/env.zig").Env;
const Object = @import("../napi/value.zig").Object;
const NapiError = @import("../napi/wrapper/error.zig");
const Napi = @import("../napi/util/napi.zig").Napi;
const Undefined = @import("../napi/value/undefined.zig").Undefined;

pub fn NODE_API_MODULE_WITH_INIT(
    comptime name: []const u8,
    comptime root: type,
    init: ?fn (env: Env, exports: Object) anyerror!?Object,
) void {
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
    };

    comptime {
        const init_array = [1]*const fn () callconv(.c) void{&ModuleImpl.module_init};
        @export(&init_array, .{ .linkage = .strong, .name = "init_array", .section = ".init_array" });
    }
}

/// This function is used to register a module without an init function.
pub fn NODE_API_MODULE(
    comptime name: []const u8,
    comptime root: type,
) void {
    NODE_API_MODULE_WITH_INIT(name, root, null);
}
