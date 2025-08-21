const napi = @import("../sys/api.zig").napi;
const Env = @import("../napi/env.zig").Env;
const Object = @import("../napi/value.zig").Object;

pub fn NODE_API_MODULE(comptime name: []const u8, comptime init: fn (env: Env, exports: Object) Object) void {
    const InitFn = struct {
        fn inner_init(env: napi.napi_env, exports: napi.napi_value) callconv(.C) napi.napi_value {
            return init(Env.from_raw(env), Object.from_raw(env, exports)).raw;
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

        fn module_init() callconv(.C) void {
            napi.napi_module_register(@constCast(&module));
        }
    };

    comptime {
        const init_array = [1]*const fn () callconv(.C) void{&ModuleImpl.module_init};
        @export(&init_array, .{ .linkage = .strong, .name = "init_array", .section = ".init_array" });
    }
}
