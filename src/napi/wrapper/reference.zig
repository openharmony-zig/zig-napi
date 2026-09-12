const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("./error.zig");
const helper = @import("../util/helper.zig");
pub fn Reference(comptime T: type) type {
    if (!@hasDecl(T, "from_raw")) {
        @compileError("Reference(T) requires T.from_raw");
    }
    if (!@hasField(T, "raw")) {
        @compileError("Reference(T) requires T.raw");
    }

    return struct {
        /// A strong JavaScript reference (`napi_ref`) plus the state of *this*
        /// copy.
        ///
        /// Ownership: the handle is owned by whoever created it. Copying a
        /// `Reference` copies the handle, not the ownership, and every copy
        /// keeps its own `taken` flag: releasing through one copy
        /// (`Unref`/`Delete`) deletes the underlying reference for all of them,
        /// so a stale alias afterwards fails with "Ref value has been deleted"
        /// only if it was itself marked taken. Keep exactly one owner per
        /// created reference and pass the reference (not a copy) to it; when a
        /// reference has to be shared, store the single owner and hand out
        /// borrowed `T` values read through `GetValue`.
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

            // A reference created while an argument conversion is running
            // belongs to that conversion until it completes. Handing it to the
            // rollback frame is what keeps the JavaScript value collectible when
            // a later argument of the same call fails (audit H04); without a
            // bookkeeping slot the conversion must fail instead of leaking.
            helper.trackReference(env.raw, raw_ref, deleteReference) catch |err| {
                _ = napi.napi_delete_reference(env.raw, raw_ref);
                return err;
            };

            return Self.from_raw(env.raw, raw_ref);
        }

        /// Rollback action for a strong reference a failing conversion created.
        /// It lives here, next to the only code that creates references, so a
        /// build that never converts one does not link `napi_delete_reference`.
        fn deleteReference(env: napi.napi_env, handle: napi.napi_ref) void {
            _ = napi.napi_delete_reference(env, handle);
        }

        /// Create a strong reference for a JavaScript value. Fails instead of
        /// aborting when the runtime refuses to create the reference.
        ///
        /// Ownership: this *creates* a strong reference. Converted as a
        /// function parameter, the reference is released again by the
        /// conversion when the call is rejected before the native body runs;
        /// once the body runs, the body owns it and must hand it back with
        /// `Unref`/`Delete` (or keep it, for example in a class field).
        pub fn from_napi_value(env: napi.napi_env, raw_value: napi.napi_value) !Self {
            const value = T.from_raw(env, raw_value);
            return try Self.New(Env.from_raw(env), value);
        }

        /// True once this copy released the reference (or was built to represent
        /// a missing value). Every operation that reads the handle refuses to
        /// run afterwards instead of dereferencing a deleted reference.
        pub fn isTaken(self: Self) bool {
            return self.taken or self.raw_ref == null;
        }

        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            return try self.get_raw_value(Env.from_raw(env));
        }

        fn get_raw_value(self: Self, env: Env) !napi.napi_value {
            if (self.isTaken()) {
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

        /// Release the reference *and* delete it: the count is dropped first
        /// (which makes the JavaScript value collectible again) and the handle
        /// is destroyed afterwards, so this reference cannot be revived with
        /// `Ref`. Callers that only need to stop counting a value must not use
        /// this; they keep the reference and pass `GetValue` around instead.
        pub fn Unref(self: *Self, env: Env) !void {
            if (self.isTaken()) {
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
            if (self.isTaken()) {
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
