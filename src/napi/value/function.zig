const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("../wrapper/error.zig");
const Undefined = @import("./undefined.zig").Undefined;
const GlobalAllocator = @import("../util/allocator.zig");
const Reference = @import("../wrapper/reference.zig").Reference;
const helper = @import("../util/helper.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;

pub fn Function(comptime Args: type, comptime Return: type) type {
    const ArgsInfos = @typeInfo(Args);
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        type: napi.napi_valuetype,
        args: Args,
        return_type: Return,

        inner_fn: ?*const fn (inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return Self{ .env = env, .raw = raw, .type = napi.napi_function, .inner_fn = null, .args = undefined, .return_type = undefined };
        }

        pub fn New(env: Env, comptime name: []const u8, value: anytype) !Self {
            const value_type = @TypeOf(value);
            const infos = @typeInfo(value_type);
            const params = infos.@"fn".params;

            if (infos != .@"fn") {
                @compileError("Function.New only support function type, Unsupported type: " ++ @typeName(value_type));
            }

            const FnImpl = struct {
                const has_env = params.len > 0 and params[0].type.? == Env;
                const env_index = if (has_env) 1 else 0;

                fn cleanupArgs(args: *std.meta.ArgsTuple(value_type), initialized: usize) void {
                    inline for (params, 0..) |param, i| {
                        if (comptime has_env and i == 0) {
                            continue;
                        }
                        if (i < initialized) {
                            Napi.deinit_napi_value(param.type.?, args[i]);
                        }
                    }
                }

                fn inner_fn(inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                    const undefined_value = Undefined.New(Env.from_raw(inner_env));
                    const return_info = infos.@"fn".return_type.?;
                    const return_payload = switch (@typeInfo(return_info)) {
                        .error_union => |eu| eu.payload,
                        else => return_info,
                    };
                    const async_returns_descriptor = comptime helper.isAsyncDescriptor(return_payload);
                    const has_async_events = comptime async_returns_descriptor and return_payload.async_has_events;
                    const expected_argc = params.len - env_index + if (has_async_events) 1 else 0;

                    var init_argc: usize = expected_argc;

                    const allocator = GlobalAllocator.globalAllocator();
                    const args_raw = allocator.alloc(napi.napi_value, init_argc) catch @panic("OOM");
                    defer allocator.free(args_raw);

                    const cb_status = napi.napi_get_cb_info(inner_env, info, &init_argc, args_raw.ptr, null, null);
                    if (cb_status != napi.napi_ok) {
                        return NapiError.checkNapiStatus(inner_env, NapiError.Status.New(cb_status));
                    }

                    var napi_params: std.meta.ArgsTuple(value_type) = undefined;
                    var initialized_params: usize = 0;
                    var cleanup_params = true;
                    defer if (cleanup_params) cleanupArgs(&napi_params, initialized_params);

                    if (comptime has_env) {
                        napi_params[0] = Env.from_raw(inner_env);
                        initialized_params = 1;
                    }

                    var abort_signal: ?AbortSignal = null;
                    inline for (params[env_index..], env_index..) |param_index, i| {
                        if (comptime @typeInfo(param_index.type.?) == .@"union") {
                            NapiError.clearLastError();
                        }
                        napi_params[i] = Napi.from_napi_value(inner_env, args_raw[i - env_index], param_index.type.?);
                        initialized_params = i + 1;
                        if (comptime helper.isAbortSignal(param_index.type.?)) {
                            abort_signal = napi_params[i];
                        }
                        if (comptime @typeInfo(param_index.type.?) == .@"union") {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(inner_env));
                                return undefined_value.raw;
                            }
                        }
                    }

                    const event_listener = if (has_async_events and init_argc > params.len - env_index)
                        args_raw[init_argc - 1]
                    else
                        null;

                    if (@typeInfo(return_info) == .error_union) {
                        const ret = @call(.auto, value, napi_params) catch {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(inner_env));
                            }
                            return undefined_value.raw;
                        };
                        if (comptime async_returns_descriptor) {
                            cleanup_params = false;
                            var task = ret;
                            const promise = task.scheduleWithListenerAndSignal(Env.from_raw(inner_env), event_listener, abort_signal) catch {
                                if (NapiError.last_error) |last_err| {
                                    last_err.throwInto(Env.from_raw(inner_env));
                                }
                                return undefined_value.raw;
                            };
                            return promise.raw;
                        }
                        const n_value = Napi.to_napi_value(inner_env, ret, null) catch {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(inner_env));
                            }
                            return undefined_value.raw;
                        };
                        return n_value;
                    } else {
                        const ret = @call(.auto, value, napi_params);
                        if (comptime async_returns_descriptor) {
                            cleanup_params = false;
                            var task = ret;
                            const promise = task.scheduleWithListenerAndSignal(Env.from_raw(inner_env), event_listener, abort_signal) catch {
                                if (NapiError.last_error) |last_err| {
                                    last_err.throwInto(Env.from_raw(inner_env));
                                }
                                return undefined_value.raw;
                            };
                            return promise.raw;
                        }
                        const n_value = Napi.to_napi_value(inner_env, ret, null) catch {
                            if (NapiError.last_error) |last_err| {
                                last_err.throwInto(Env.from_raw(inner_env));
                            }
                            return undefined_value.raw;
                        };
                        return n_value;
                    }
                }
            };

            var result: napi.napi_value = undefined;
            const fn_status = napi.napi_create_function(env.raw, @ptrCast(name.ptr), 0, FnImpl.inner_fn, null, &result);
            if (fn_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(fn_status));
            }
            var func = Self.from_raw(env.raw, result);
            func.inner_fn = FnImpl.inner_fn;
            return func;
        }

        /// Call the function with the given arguments
        /// ```zig
        /// const fns = Function.New(env, "fn", fn (a: i32, b: i32) i32 {
        ///     return a + b;
        /// });
        /// const result = try fns.Call(.{1, 2});
        /// std.debug.print("result: {}\n", .{result});
        /// ```
        /// Args should be a tuple.
        pub fn Call(self: Self, args: Args) !Return {
            const isTuple = ArgsInfos == .@"struct" and ArgsInfos.@"struct".is_tuple;

            const args_len = if (isTuple) ArgsInfos.@"struct".fields.len else 1;

            const allocator = GlobalAllocator.globalAllocator();
            const args_raw = allocator.alloc(napi.napi_value, args_len) catch @panic("OOM");
            defer allocator.free(args_raw);

            if (isTuple) {
                inline for (ArgsInfos.@"struct".fields, 0..) |arg, i| {
                    args_raw[i] = try Napi.to_napi_value(self.env, @field(args, arg.name), null);
                }
            } else {
                args_raw[0] = try Napi.to_napi_value(self.env, args, null);
            }

            const this = Undefined.New(Env.from_raw(self.env));

            var result: napi.napi_value = undefined;

            const status = napi.napi_call_function(self.env, this.raw, self.raw, args_len, args_raw.ptr, &result);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            if (comptime @typeInfo(Return) == .@"union") {
                NapiError.clearLastError();
                const converted = Napi.from_napi_value(self.env, result, Return);
                if (NapiError.last_error) |_| {
                    return error.GenericFailure;
                }
                return converted;
            }
            return Napi.from_napi_value(self.env, result, Return);
        }

        pub fn CreateRef(self: Self) !Reference(Self) {
            return Reference(Self).New(Env.from_raw(self.env), self);
        }
    };
}
