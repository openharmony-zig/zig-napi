const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("./error.zig");
pub fn Reference(comptime T: type) type {
    if (!@hasDecl(T, "from_raw")) {
        @compileError("Reference(T) requires T.from_raw");
    }
    if (!@hasField(T, "raw")) {
        @compileError("Reference(T) requires T.raw");
    }

    return struct {
        pub const is_napi_reference = true;
        pub const referenced_type = T;

        raw_ref: napi.napi_ref,
        taken: bool,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_ref) Self {
            _ = env;
            return Self{
                .raw_ref = raw,
                .taken = false,
            };
        }

        pub fn New(env: Env, value: T) !Self {
            var raw_ref: napi.napi_ref = undefined;
            const status = napi.napi_create_reference(env.raw, value.raw, 1, &raw_ref);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            return Self.from_raw(env.raw, raw_ref);
        }

        pub fn from_napi_value(env: napi.napi_env, raw_value: napi.napi_value) Self {
            const value = T.from_raw(env, raw_value);
            return Self.New(Env.from_raw(env), value) catch @panic("Failed to create reference");
        }

        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            return try self.get_raw_value(Env.from_raw(env));
        }

        fn get_raw_value(self: Self, env: Env) !napi.napi_value {
            if (self.taken) {
                return NapiError.Error.fromStatus(@as([]const u8, "Ref value has been deleted"));
            }

            var raw_value: napi.napi_value = undefined;
            const status = napi.napi_get_reference_value(env.raw, self.raw_ref, &raw_value);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            if (raw_value == null) {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            }

            return raw_value;
        }

        pub fn get_value(self: Self, env: Env) !T {
            const raw_value = try self.get_raw_value(env);
            return T.from_raw(env.raw, raw_value);
        }

        pub fn GetValue(self: Self, env: Env) !T {
            const raw_value = try self.get_raw_value(env);
            return T.from_raw(env.raw, raw_value);
        }

        pub fn Unref(self: *Self, env: Env) !void {
            if (self.taken or self.raw_ref == null) {
                return NapiError.Error.fromStatus(@as([]const u8, "Ref value has been deleted"));
            }

            var count: u32 = 0;
            const unref_status = napi.napi_reference_unref(env.raw, self.raw_ref, &count);
            if (unref_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(unref_status));
            }

            const delete_status = napi.napi_delete_reference(env.raw, self.raw_ref);
            if (delete_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(delete_status));
            }

            self.taken = true;
            self.raw_ref = null;
        }

        pub fn Ref(self: *Self, env: Env) !u32 {
            if (self.taken or self.raw_ref == null) {
                return NapiError.Error.fromStatus(@as([]const u8, "Ref value has been deleted"));
            }

            var count: u32 = 0;
            const status = napi.napi_reference_ref(env.raw, self.raw_ref, &count);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
            return count;
        }

        pub fn Delete(self: *Self, env: Env) !void {
            return Self.Unref(self, env);
        }
    };
}
