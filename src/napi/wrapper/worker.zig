const std = @import("std");
const napi = @import("napi-sys");
const napi_env = @import("../env.zig");
const String = @import("../value/string.zig").String;
const napi_status = @import("./status.zig");
const Value = @import("../value.zig").Value;
const Promise = @import("../value/promise.zig").Promise;
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("./error.zig");

const WorkerStatus = enum {
    Pending,
    Resolved,
    Rejected,
    Cancelled,
};

pub fn WorkerContext(comptime T: type) type {
    const hasData = comptime @hasField(T, "data");
    const hasExecute = comptime @hasField(T, "Execute");

    if (!hasData) {
        @compileError("Worker must init with data field");
    }

    if (!hasExecute) {
        @compileError("Worker must init with Execute field");
    }

    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("T must be a struct type");
    }

    const DataType = @TypeOf(@as(T, undefined).data);
    const ExecuteFn = @TypeOf(@as(T, undefined).Execute);
    const ExecuteFnInfos = @typeInfo(ExecuteFn);
    const OnComplete = @TypeOf(@as(T, undefined).OnComplete);
    const OnCompleteInfos = @typeInfo(OnComplete);

    const ExecuteResult = ExecuteFnInfos.@"fn".return_type.?;

    if (ExecuteFnInfos != .@"fn") {
        @compileError("Execute must be a function");
    }

    if (OnCompleteInfos != .@"fn") {
        @compileError("OnComplete must be a function");
    }

    return struct {
        data: T,
        env: napi.napi_env,
        raw: napi.napi_async_work,
        allocator: std.mem.Allocator,
        result: ExecuteResult,
        status: WorkerStatus,
        promise: ?*Promise,

        const Self = @This();

        pub fn New(env: napi_env.Env, init_data: anytype) *Self {
            const Execute = struct {
                fn inner_execute(inner_env: napi.napi_env, data: ?*anyopaque) callconv(.C) void {
                    const inner_self: *Self = @ptrCast(@alignCast(data));
                    const params = ExecuteFnInfos.@"fn".params;

                    switch (params.len) {
                        1 => {
                            if (params[0].type.? != DataType) {
                                @compileError("Execute's first parameter must be " ++ @typeName(DataType));
                            } else {
                                inner_self.result = inner_self.data.Execute(inner_self.data.data);
                                inner_self.status = .Resolved;
                            }
                        },
                        2 => {
                            if (params[0].type.? != napi_env.Env) {
                                @compileError("Execute's first parameter must be napi.Env");
                            } else if (params[1].type.? != DataType) {
                                @compileError("Execute's second parameter must be " ++ @typeName(DataType));
                            } else {
                                inner_self.result = inner_self.data.Execute(napi_env.Env.from_raw(inner_env), inner_self.data.data);
                                inner_self.status = .Resolved;
                            }
                        },
                        else => {
                            @compileError("Execute must have 1 or 2 parameters, but got " ++ std.fmt.comptimePrint("{d}", .{params.len}));
                        },
                    }
                }
            };

            const Complete = struct {
                fn inner_complete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.C) void {
                    const inner_self: *Self = @ptrCast(@alignCast(data));
                    const napi_data = Napi.to_napi_value(inner_env, inner_self.result, null) catch {
                        if (NapiError.last_error) |last_err| {
                            last_err.throwInto(napi_env.Env.from_raw(inner_env));
                        }
                        return;
                    };
                    switch (inner_self.status) {
                        .Rejected => {
                            if (inner_self.promise) |promise| {
                                promise.Reject(napi_data) catch {
                                    if (NapiError.last_error) |last_err| {
                                        last_err.throwInto(napi_env.Env.from_raw(inner_env));
                                    }
                                    return;
                                };
                            }
                        },
                        .Resolved => {
                            if (inner_self.promise) |promise| {
                                promise.Resolve(napi_data) catch {
                                    if (NapiError.last_error) |last_err| {
                                        last_err.throwInto(napi_env.Env.from_raw(inner_env));
                                    }
                                    return;
                                };
                            }
                        },
                        else => {},
                    }
                    const hasComplete = comptime @hasField(T, "OnComplete");
                    if (hasComplete) {
                        const params = OnCompleteInfos.@"fn".params;
                        switch (params.len) {
                            1 => {
                                if (params[0].type.? != DataType) {
                                    @compileError("OnComplete's first parameter must be " ++ @typeName(DataType));
                                } else {
                                    inner_self.data.OnComplete(inner_self.data.data);
                                }
                            },
                            2 => {
                                if (params[0].type.? != napi_env.Env) {
                                    @compileError("OnComplete's first parameter must be napi.Env");
                                } else if (params[1].type.? != DataType) {
                                    @compileError("OnComplete's second parameter must be napi.Status");
                                } else {
                                    inner_self.data.OnComplete(napi_env.Env.from_raw(inner_env), inner_self.data.data);
                                }
                            },
                            3 => {
                                if (params[0].type.? != napi_env.Env) {
                                    @compileError("OnComplete's first parameter must be napi.Env");
                                } else if (params[1].type.? != napi_status.Status) {
                                    @compileError("OnComplete's second parameter must be napi_status.Status");
                                } else if (params[2].type.? != DataType) {
                                    @compileError("OnComplete's third parameter must be " ++ @typeName(DataType));
                                } else {
                                    inner_self.data.OnComplete(napi_env.Env.from_raw(inner_env), napi_status.Status.from_raw(status), inner_self.data.data);
                                }
                            },
                            else => {
                                @compileError("OnComplete must have 1 or 2 parameters, but got " ++ std.fmt.comptimePrint("{d}", .{params.len}));
                            },
                        }
                    }
                    inner_self.deinit();
                }
            };

            const allocator = std.heap.page_allocator;
            var self = allocator.create(Self) catch @panic("OOM");

            self.* = Self{
                .data = init_data,
                .env = env.raw,
                .raw = undefined,
                .allocator = allocator,
                .result = undefined,
                .status = .Pending,
                .promise = null,
            };

            const async_resource_name = String.New(env, "AsyncWorkerCallback");

            var result: napi.napi_async_work = undefined;
            _ = napi.napi_create_async_work(env.raw, null, async_resource_name.raw, Execute.inner_execute, Complete.inner_complete, @ptrCast(self), &result);

            self.raw = result;

            return self;
        }

        pub fn deinit(self: *Self) void {
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
    };
}

pub fn Worker(env: napi_env.Env, data: anytype) *WorkerContext(@TypeOf(data)) {
    return WorkerContext(@TypeOf(data)).New(env, data);
}
