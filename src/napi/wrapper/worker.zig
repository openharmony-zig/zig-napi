const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const napi_env = @import("../env.zig");
const String = @import("../value/string.zig").String;
const Promise = @import("../value/promise.zig").Promise;
const NapiError = @import("./error.zig");
const GlobalAllocator = @import("../util/allocator.zig");

const WorkerStatus = enum {
    Pending,
    Resolved,
    Rejected,
    Cancelled,
};

pub fn WorkerContext(comptime T: type) type {
    const has_data = comptime @hasField(T, "data");
    const has_execute = comptime @hasField(T, "Execute");
    const has_on_complete = comptime @hasField(T, "OnComplete");

    if (!has_data) {
        @compileError("Worker must init with data field");
    }
    if (!has_execute) {
        @compileError("Worker must init with Execute field");
    }
    if (@typeInfo(T) != .@"struct") {
        @compileError("Worker init data must be a struct");
    }

    const DataType = @TypeOf(@as(T, undefined).data);
    const ExecuteFn = @TypeOf(@as(T, undefined).Execute);
    const ExecuteInfo = @typeInfo(ExecuteFn);
    if (ExecuteInfo != .@"fn") {
        @compileError("Execute must be a function");
    }

    const ExecuteReturn = ExecuteInfo.@"fn".return_type.?;
    const ExecutePayload = switch (@typeInfo(ExecuteReturn)) {
        .error_union => |eu| eu.payload,
        else => ExecuteReturn,
    };

    comptime validateExecuteSignature(DataType, ExecuteFn);

    if (has_on_complete) {
        const OnComplete = @TypeOf(@as(T, undefined).OnComplete);
        if (@typeInfo(OnComplete) != .@"fn") {
            @compileError("OnComplete must be a function");
        }
        comptime validateOnCompleteSignature(DataType, OnComplete);
    }

    return struct {
        data: T,
        env: napi.napi_env,
        raw: napi.napi_async_work,
        allocator: std.mem.Allocator,
        result: ExecutePayload = if (ExecutePayload == void) {} else undefined,
        err: ?NapiError.Error = null,
        status: WorkerStatus = .Pending,
        promise: ?*Promise = null,

        const Self = @This();

        pub fn New(env: napi_env.Env, init_data: anytype) *Self {
            const allocator = GlobalAllocator.globalAllocator();
            const self = allocator.create(Self) catch @panic("OOM");

            self.* = .{
                .data = init_data,
                .env = env.raw,
                .raw = null,
                .allocator = allocator,
            };

            const async_resource_name = String.New(env, "AsyncWorkerCallback");

            var result: napi.napi_async_work = null;
            const status = napi.napi_create_async_work(
                env.raw,
                null,
                async_resource_name.raw,
                execute,
                complete,
                @ptrCast(self),
                &result,
            );
            if (status != napi.napi_ok) {
                allocator.destroy(self);
                @panic("Failed to create async worker");
            }

            self.raw = result;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.raw != null) {
                _ = napi.napi_delete_async_work(self.env, self.raw);
                self.raw = null;
            }
            if (self.promise) |promise| {
                self.allocator.destroy(promise);
                self.promise = null;
            }
            self.allocator.destroy(self);
        }

        pub fn Queue(self: *Self) void {
            _ = napi.napi_queue_async_work(self.env, self.raw);
        }

        pub fn AsyncQueue(self: *Self) Promise {
            const promise = self.allocator.create(Promise) catch @panic("OOM");
            promise.* = Promise.New(napi_env.Env.from_raw(self.env));
            self.promise = promise;
            _ = napi.napi_queue_async_work(self.env, self.raw);
            return promise.*;
        }

        pub fn Cancel(self: *Self) void {
            _ = napi.napi_cancel_async_work(self.env, self.raw);
        }

        fn execute(inner_env: napi.napi_env, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            NapiError.clearLastError();
            self.run(inner_env) catch {
                self.status = .Rejected;
                self.err = NapiError.last_error orelse NapiError.Error.withStatus("GenericFailure");
                return;
            };
            self.status = .Resolved;
        }

        fn complete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            defer self.deinit();

            if (status == napi.napi_cancelled) {
                self.status = .Cancelled;
            }

            switch (self.status) {
                .Rejected => {
                    if (self.promise) |promise| {
                        if (self.err) |err| {
                            promise.Reject(err) catch {
                                if (NapiError.last_error) |last_err| {
                                    last_err.throwInto(napi_env.Env.from_raw(inner_env));
                                }
                            };
                        }
                    } else if (self.err) |err| {
                        err.throwInto(napi_env.Env.from_raw(inner_env));
                    }
                },
                .Resolved => {
                    if (self.promise) |promise| {
                        if (ExecutePayload == void) {
                            promise.Resolve({}) catch {};
                        } else {
                            promise.Resolve(self.result) catch {
                                if (NapiError.last_error) |last_err| {
                                    last_err.throwInto(napi_env.Env.from_raw(inner_env));
                                }
                            };
                        }
                    }
                },
                else => {},
            }

            if (has_on_complete) {
                callOnComplete(self.data, napi_env.Env.from_raw(inner_env));
            }
        }

        fn run(self: *Self, inner_env: napi.napi_env) !void {
            const execute_fn = self.data.Execute;
            if (@typeInfo(ExecuteReturn) == .error_union) {
                if (ExecutePayload == void) {
                    if (ExecuteInfo.@"fn".params.len == 1) {
                        try execute_fn(self.data.data);
                    } else {
                        try execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                    }
                } else {
                    self.result = if (ExecuteInfo.@"fn".params.len == 1)
                        try execute_fn(self.data.data)
                    else
                        try execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                }
            } else {
                if (ExecutePayload == void) {
                    if (ExecuteInfo.@"fn".params.len == 1) {
                        _ = execute_fn(self.data.data);
                    } else {
                        _ = execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                    }
                } else {
                    self.result = if (ExecuteInfo.@"fn".params.len == 1)
                        execute_fn(self.data.data)
                    else
                        execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                }
            }
        }
    };
}

fn validateExecuteSignature(comptime DataType: type, comptime ExecuteFn: type) void {
    const info = @typeInfo(ExecuteFn).@"fn";
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("Worker Execute must accept (data) or (napi.Env, data)");
    }

    if (info.params.len == 1) {
        if (info.params[0].type.? != DataType) {
            @compileError("Worker Execute data type mismatch");
        }
    } else {
        if (info.params[0].type.? != napi_env.Env) {
            @compileError("Worker Execute first parameter must be napi.Env");
        }
        if (info.params[1].type.? != DataType) {
            @compileError("Worker Execute data type mismatch");
        }
    }
}

fn validateOnCompleteSignature(comptime DataType: type, comptime OnCompleteFn: type) void {
    const info = @typeInfo(OnCompleteFn).@"fn";
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("Worker OnComplete must accept (data) or (napi.Env, data)");
    }

    if (info.params.len == 1) {
        if (info.params[0].type.? != DataType) {
            @compileError("Worker OnComplete data type mismatch");
        }
    } else {
        if (info.params[0].type.? != napi_env.Env) {
            @compileError("Worker OnComplete first parameter must be napi.Env");
        }
        if (info.params[1].type.? != DataType) {
            @compileError("Worker OnComplete data type mismatch");
        }
    }
}

fn callOnComplete(data: anytype, env: napi_env.Env) void {
    const OnCompleteFn = @TypeOf(data.OnComplete);
    const info = @typeInfo(OnCompleteFn).@"fn";
    if (info.params.len == 1) {
        data.OnComplete(data.data);
    } else {
        data.OnComplete(env, data.data);
    }
}

pub fn Worker(env: napi_env.Env, data: anytype) *WorkerContext(@TypeOf(data)) {
    return WorkerContext(@TypeOf(data)).New(env, data);
}
