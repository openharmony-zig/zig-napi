const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("../wrapper/error.zig");
const Undefined = @import("./undefined.zig").Undefined;
const Reference = @import("../wrapper/reference.zig").Reference;
const helper = @import("../util/helper.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const GlobalAllocator = @import("../util/allocator.zig");

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

        pub fn New(env: Env, comptime function_name: []const u8, value: anytype) !Self {
            const value_type = @TypeOf(value);
            const infos = @typeInfo(value_type);
            const params = infos.@"fn".param_types;

            if (infos != .@"fn") {
                @compileError("Function.New only support function type, Unsupported type: " ++ @typeName(value_type));
            }

            const FnImpl = struct {
                const has_env = params.len > 0 and params[0].? == Env;
                const env_index = if (has_env) 1 else 0;
                const this_count = blk: {
                    var count: usize = 0;
                    for (params) |param| if (helper.isThis(param.?)) {
                        count += 1;
                    };
                    break :blk count;
                };

                fn cleanupArgs(args: *std.meta.ArgsTuple(value_type), initialized: usize, allocator: std.mem.Allocator) void {
                    inline for (params, 0..) |param, i| {
                        if (comptime has_env and i == 0) {
                            continue;
                        }
                        if (i < initialized) {
                            Napi.deinit_napi_value_with_allocator(param.?, args[i], allocator);
                        }
                    }
                }

                fn returnPayloadType(comptime T: type) type {
                    const payload = switch (@typeInfo(T)) {
                        .error_union => |eu| eu.payload,
                        else => T,
                    };
                    return if (comptime NapiError.isResult(payload)) NapiError.resultPayload(payload) else payload;
                }

                fn undefinedValue(inner_env: napi.napi_env) napi.napi_value {
                    const undefined_value = Undefined.create(Env.from_raw(inner_env)) catch @panic("napi: failed to create undefined value");
                    return undefined_value.raw;
                }

                /// Return `undefined` while a JavaScript exception is already
                /// pending. The engine propagates the original exception object;
                /// creating a new one here would replace it.
                fn propagatePending(inner_env: napi.napi_env) napi.napi_value {
                    return undefinedValue(inner_env);
                }

                fn isPending(err: anyerror) bool {
                    return err == error.PendingException or NapiError.hasPendingException();
                }

                fn throwAndUndefined(inner_env: napi.napi_env, err: NapiError.Error) napi.napi_value {
                    if (NapiError.hasPendingException()) {
                        return propagatePending(inner_env);
                    }
                    err.throwInto(Env.from_raw(inner_env));
                    return undefinedValue(inner_env);
                }

                fn throwAnyAndUndefined(inner_env: napi.napi_env, err: anyerror) napi.napi_value {
                    if (isPending(err)) {
                        return propagatePending(inner_env);
                    }
                    return throwAndUndefined(inner_env, NapiError.mapAnyError(err));
                }

                fn completePayload(
                    inner_env: napi.napi_env,
                    payload: anytype,
                    event_listener: napi.napi_value,
                    abort_signal: ?AbortSignal,
                    allocator: std.mem.Allocator,
                ) napi.napi_value {
                    if (comptime helper.isAsyncDescriptor(@TypeOf(payload))) {
                        var task = payload;
                        const promise = task.scheduleWithListenerAndSignal(Env.from_raw(inner_env), event_listener, abort_signal) catch |err| {
                            return throwAnyAndUndefined(inner_env, err);
                        };
                        return promise.raw;
                    }

                    // A plain return is borrowed: its container, literals and
                    // aliases are never freed. Only explicit `Owned` nodes (at
                    // the top level or nested inside the returned value) transfer
                    // ownership to this call, and they are disposed after the
                    // JavaScript value has been built - on success and on a
                    // failed output conversion alike.
                    if (comptime Napi.containsOwnedValue(@TypeOf(payload))) {
                        defer Napi.disposeOwnedParts(@TypeOf(payload), payload, allocator);
                        return Napi.to_napi_value_auto(inner_env, payload, null) catch |err| {
                            return throwAnyAndUndefined(inner_env, err);
                        };
                    }

                    return Napi.to_napi_value_auto(inner_env, payload, null) catch |err| {
                        return throwAnyAndUndefined(inner_env, err);
                    };
                }

                fn completeReturn(
                    inner_env: napi.napi_env,
                    ret: anytype,
                    event_listener: napi.napi_value,
                    abort_signal: ?AbortSignal,
                    allocator: std.mem.Allocator,
                ) napi.napi_value {
                    if (comptime NapiError.isResult(@TypeOf(ret))) {
                        return switch (ret) {
                            .ok => |payload| completePayload(inner_env, payload, event_listener, abort_signal, allocator),
                            .err => |err| throwAndUndefined(inner_env, err),
                        };
                    }

                    return completePayload(inner_env, ret, event_listener, abort_signal, allocator);
                }

                fn inner_fn(inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                    // Callback entry is a nested JavaScript entry point: keep the
                    // error state of the embedding frame intact and never leak
                    // callback local errors into it.
                    const outer_frame = NapiError.ErrorFrame.save();
                    defer outer_frame.restore();
                    NapiError.clearLastError();

                    const return_info = infos.@"fn".return_type.?;
                    const return_payload = returnPayloadType(return_info);
                    const async_returns_descriptor = comptime helper.isAsyncDescriptor(return_payload);
                    const has_async_events = comptime async_returns_descriptor and return_payload.async_has_events;
                    const expected_argc = params.len - env_index - this_count + if (has_async_events) 1 else 0;

                    var init_argc: usize = expected_argc;
                    var args_raw: [expected_argc]napi.napi_value = undefined;
                    const args_ptr = if (expected_argc == 0) null else args_raw[0..].ptr;

                    var receiver: napi.napi_value = null;
                    const cb_status = napi.napi_get_cb_info(inner_env, info, &init_argc, args_ptr, &receiver, null);
                    if (cb_status != napi.napi_ok) {
                        return NapiError.checkNapiStatus(inner_env, NapiError.Status.New(cb_status));
                    }
                    const copied_argc = @min(init_argc, expected_argc);
                    if (expected_argc > copied_argc) {
                        const undefined_value = Undefined.New(Env.from_raw(inner_env));
                        for (copied_argc..expected_argc) |i| {
                            args_raw[i] = undefined_value.raw;
                        }
                    }

                    // Every converted argument is a native copy owned by this call
                    // scope: it is released on both the success and the failure
                    // path. The allocator is captured *once* here and threaded
                    // through the conversion and the cleanup, so a reentrant
                    // JavaScript callback that replaces this thread's operation
                    // allocator cannot make cleanup use a different allocator than
                    // the one that produced the copies. Async descriptors clone
                    // what they capture themselves.
                    const frame_allocator = GlobalAllocator.capture();

                    // Argument conversion is a transaction. Converting a
                    // parameter may *create* a JavaScript resource - a strong
                    // reference for `napi.Reference(T)`/`napi.ObjectRef`, an
                    // active thread-safe function for a TSFN pointer - and none
                    // of those may survive a call that never reached its body
                    // (audit H04). The frame releases them before the native
                    // cleanup runs and is committed once the body is about to be
                    // entered: from that point on the resources belong to the
                    // body (a TSFN is routinely handed to another thread).
                    var conversion = helper.ConversionFrame{};
                    conversion.start(frame_allocator);
                    defer conversion.end();

                    var napi_params: std.meta.ArgsTuple(value_type) = undefined;
                    var initialized_params: usize = 0;
                    defer cleanupArgs(&napi_params, initialized_params, frame_allocator);
                    // Registered after the native cleanup so it runs *before* it:
                    // a rollback handle may live inside memory the cleanup frees
                    // (for example a slice of references).
                    defer conversion.rollbackUncommitted();

                    if (comptime has_env) {
                        napi_params[0] = Env.from_raw(inner_env);
                        initialized_params = 1;
                    }

                    var abort_signal: ?AbortSignal = null;
                    var positional: usize = 0;
                    inline for (params[env_index..], env_index..) |param_index, i| {
                        NapiError.clearLastError();
                        const converted = Napi.from_napi_value_auto_with_allocator(
                            inner_env,
                            if (comptime helper.isThis(param_index.?)) receiver else args_raw[positional],
                            param_index.?,
                            frame_allocator,
                        ) catch |err| {
                            return throwAnyAndUndefined(inner_env, err);
                        };
                        napi_params[i] = converted;
                        initialized_params = i + 1;
                        if (comptime !helper.isThis(param_index.?)) positional += 1;
                        if (comptime helper.isAbortSignal(param_index.?)) {
                            abort_signal = napi_params[i];
                        }
                    }

                    const event_listener = if (has_async_events and copied_argc > params.len - env_index - this_count)
                        args_raw[copied_argc - 1]
                    else
                        null;

                    if (@typeInfo(return_info) == .error_union) {
                        conversion.commit();
                        const ret = @call(.auto, value, napi_params) catch |err| {
                            return throwAnyAndUndefined(inner_env, err);
                        };
                        return completeReturn(inner_env, ret, event_listener, abort_signal, frame_allocator);
                    } else {
                        conversion.commit();
                        const ret = @call(.auto, value, napi_params);
                        return completeReturn(inner_env, ret, event_listener, abort_signal, frame_allocator);
                    }
                }
            };

            var result: napi.napi_value = undefined;
            const fn_status = napi.napi_create_function(env.raw, @ptrCast(function_name.ptr), 0, FnImpl.inner_fn, null, &result);
            if (fn_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(fn_status));
            }
            var func = Self.from_raw(env.raw, result);
            func.inner_fn = FnImpl.inner_fn;
            return func;
        }

        /// Move context into the JavaScript function. If Context defines deinit,
        /// its finalizer calls deinit(*Context) before releasing the allocation.
        pub fn NewClosure(env: Env, name_: []const u8, context: anytype, comptime callback: anytype) !Self {
            const Context = @TypeOf(context);
            const Closure = struct {
                allocator: std.mem.Allocator,
                context: Context,

                fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                    const state: *@This() = @ptrCast(@alignCast(data.?));
                    const allocator = state.allocator;
                    if (comptime @typeInfo(Context) == .@"struct" and @hasDecl(Context, "deinit")) state.context.deinit();
                    allocator.destroy(state);
                }

                fn invoke(inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                    const frame = NapiError.ErrorFrame.save();
                    NapiError.clearLastError();
                    defer frame.restore();
                    const count = if (ArgsInfos == .@"struct" and ArgsInfos.@"struct".is_tuple) ArgsInfos.@"struct".field_names.len else if (ArgsInfos == .@"struct" and ArgsInfos.@"struct".field_names.len == 0) 0 else 1;
                    var argv: [count]napi.napi_value = undefined;
                    var argc: usize = count;
                    var data: ?*anyopaque = null;
                    const status = napi.napi_get_cb_info(inner_env, info, &argc, if (count == 0) null else &argv, null, &data);
                    if (status != napi.napi_ok) {
                        const err = NapiError.failStatus(status);
                        NapiError.mapAnyError(err).throwInto(Env.from_raw(inner_env));
                        NapiError.throwCurrent(Env.from_raw(inner_env));
                        return null;
                    }
                    const state: *@This() = @ptrCast(@alignCast(data.?));
                    const allocator = GlobalAllocator.capture();
                    var conversion = Napi.ConversionFrame{};
                    conversion.start(allocator);
                    defer conversion.end();
                    var args: Args = undefined;
                    var initialized: usize = 0;
                    defer {
                        if (comptime ArgsInfos == .@"struct" and ArgsInfos.@"struct".is_tuple) Napi.cleanupStructPrefix(Args, &args, initialized, allocator) else if (initialized != 0) Napi.deinit_napi_value_with_allocator(Args, args, allocator);
                    }
                    defer conversion.rollbackUncommitted();
                    if (argc < count) {
                        const err = NapiError.failTypeError("Expected {d} callback arguments, got {d}", .{ count, argc });
                        NapiError.mapAnyError(err).throwInto(Env.from_raw(inner_env));
                        NapiError.throwCurrent(Env.from_raw(inner_env));
                        return null;
                    }
                    if (comptime count == 0) {
                        args = .{};
                    } else if (comptime ArgsInfos == .@"struct" and ArgsInfos.@"struct".is_tuple) {
                        inline for (ArgsInfos.@"struct".field_types, 0..) |field_type, i| {
                            args[i] = Napi.from_napi_value_auto_with_allocator(inner_env, argv[i], field_type, allocator) catch {
                                NapiError.throwCurrent(Env.from_raw(inner_env));
                                return null;
                            };
                            initialized += 1;
                        }
                    } else {
                        args = Napi.from_napi_value_auto_with_allocator(inner_env, argv[0], Args, allocator) catch {
                            NapiError.throwCurrent(Env.from_raw(inner_env));
                            return null;
                        };
                        initialized = 1;
                    }
                    conversion.commit();
                    const result = callback(&state.context, Env.from_raw(inner_env), if (comptime count == 0) .{} else args) catch |err| {
                        if (err != error.PendingException and !NapiError.hasPendingException()) NapiError.mapAnyError(err).throwInto(Env.from_raw(inner_env));
                        return null;
                    };
                    defer if (comptime Napi.containsOwnedValue(@TypeOf(result))) Napi.disposeOwnedParts(@TypeOf(result), result, allocator);
                    return Napi.to_napi_value_auto(inner_env, result, null) catch {
                        NapiError.throwCurrent(Env.from_raw(inner_env));
                        return null;
                    };
                }
            };
            const allocator = GlobalAllocator.capture();
            const state = try allocator.create(Closure);
            errdefer allocator.destroy(state);
            state.* = .{ .allocator = allocator, .context = context };
            var raw: napi.napi_value = null;
            var status = napi.napi_create_function(env.raw, name_.ptr, name_.len, Closure.invoke, state, &raw);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            status = napi.napi_add_finalizer(env.raw, raw, state, Closure.finalize, null, null);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            return Self.from_raw(env.raw, raw);
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
        ///
        /// When the callback throws, `error.PendingException` is returned and the
        /// original JavaScript exception stays pending in the environment.
        pub fn Call(self: Self, args: Args) !Return {
            const receiver = try Undefined.create(Env.from_raw(self.env));
            return self.Apply(receiver, args);
        }

        pub fn Apply(self: Self, receiver: anytype, args: Args) !Return {
            const raw = try self.invoke(receiver, args, false);
            NapiError.clearLastError();
            if (comptime Return == void) return;
            return Napi.from_napi_value_auto(self.env, raw, Return);
        }

        pub fn NewInstance(self: Self, args: Args) !@import("./object.zig").Object {
            return @import("./object.zig").Object.from_raw(self.env, try self.invoke({}, args, true));
        }

        pub fn Bind(self: Self, receiver: anytype) !Self {
            var bind: napi.napi_value = undefined;
            var result: napi.napi_value = undefined;
            const get_status = napi.napi_get_named_property(self.env, self.raw, "bind", &bind);
            if (get_status != napi.napi_ok) return NapiError.failStatus(get_status);
            const raw_receiver = try Napi.to_napi_value_auto(self.env, receiver, null);
            const status = napi.napi_call_function(self.env, self.raw, bind, 1, @ptrCast(&raw_receiver), &result);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            return Self.from_raw(self.env, result);
        }

        pub fn name(self: Self) !@import("./string.zig").String {
            var result: napi.napi_value = undefined;
            const status = napi.napi_get_named_property(self.env, self.raw, "name", &result);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            return @import("./string.zig").String.from_raw(self.env, result);
        }

        fn invoke(self: Self, receiver: anytype, args: Args, comptime construct: bool) !napi.napi_value {
            const isTuple = ArgsInfos == .@"struct" and ArgsInfos.@"struct".is_tuple;
            const isEmptyStruct = ArgsInfos == .@"struct" and ArgsInfos.@"struct".field_names.len == 0;

            const args_len = if (isEmptyStruct) 0 else if (isTuple) ArgsInfos.@"struct".field_names.len else 1;

            var args_raw: [args_len]napi.napi_value = undefined;

            if (isEmptyStruct) {
                // No arguments.
            } else if (isTuple) {
                inline for (ArgsInfos.@"struct".field_names, 0..) |arg_name, i| {
                    args_raw[i] = try Napi.to_napi_value_auto(self.env, @field(args, arg_name), null);
                }
            } else {
                args_raw[0] = try Napi.to_napi_value_auto(self.env, args, null);
            }

            var result: napi.napi_value = undefined;

            const args_ptr = if (args_len == 0) null else args_raw[0..].ptr;
            const status = if (construct)
                napi.napi_new_instance(self.env, self.raw, args_len, args_ptr, &result)
            else
                napi.napi_call_function(self.env, try Napi.to_napi_value_auto(self.env, receiver, null), self.raw, args_len, args_ptr, &result);
            if (status != napi.napi_ok) return NapiError.failStatus(status);
            return result;
        }

        pub fn CreateRef(self: Self) !Reference(Self) {
            return Reference(Self).New(Env.from_raw(self.env), self);
        }
    };
}
