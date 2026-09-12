const std = @import("std");
const env = @import("./napi/env.zig");
const value = @import("./napi/value.zig");
const function = @import("./napi/value/function.zig");
const callback_info = @import("./napi/wrapper/callback_info.zig");
const module = @import("./prelude/module.zig");
const worker = @import("./napi/wrapper/worker.zig");
const err = @import("./napi/wrapper/error.zig");
const thread_safe_function = @import("./napi/wrapper/thread_safe_function.zig");
const async = @import("./napi/async.zig");
const abort_signal = @import("./napi/abort_signal.zig");
const class = @import("./napi/wrapper/class.zig");
const buffer = @import("./napi/wrapper/buffer.zig");
const arraybuffer = @import("./napi/wrapper/arraybuffer.zig");
const typedarray = @import("./napi/wrapper/typedarray.zig");
const dataview = @import("./napi/wrapper/dataview.zig");
const reference = @import("./napi/wrapper/reference.zig");
const external = @import("./napi/wrapper/external.zig");
const native_wrap = @import("./napi/wrapper/native_wrap.zig");
const global_allocator = @import("./napi/util/allocator.zig");
const options = @import("./napi/options.zig");
const dts_override = @import("./napi/dts.zig");
const ownership = @import("./napi/ownership.zig");

pub const napi_sys = @import("napi-sys");
pub const NapiVersion = options.NapiVersion;
pub const selectedNapiVersion = options.selectedNapiVersion;
pub const experimentalEnabled = options.experimentalEnabled;
pub const Env = env.Env;
pub const NapiValue = value.NapiValue;
pub const Object = value.Object;
pub const Number = value.Number;
pub const String = value.String;
pub const BigInt = value.BigInt;
pub const Null = value.Null;
pub const Undefined = value.Undefined;
pub const Promise = value.Promise;
pub const Bool = value.Bool;
pub const Array = value.Array;

pub const Error = err.Error;
pub const Status = err.Status;
pub const Result = err.Result;
pub const JsError = err.JsError;
pub const JsTypeError = err.JsTypeError;
pub const JsRangeError = err.JsRangeError;

pub const Function = function.Function;
pub const CallbackInfo = callback_info.CallbackInfo;
pub const Worker = worker.Worker;
pub const ThreadSafeFunction = thread_safe_function.ThreadSafeFunction;
pub const ThreadSafeFunctionMode = thread_safe_function.ThreadSafeFunctionMode;
pub const ThreadSafeFunctionReleaseMode = thread_safe_function.ThreadSafeFunctionReleaseMode;
pub const AsyncRuntime = async.RuntimeModel;
pub const CancelToken = async.CancelToken;
pub const AbortSignal = abort_signal.AbortSignal;
pub const resolveRequestedRuntime = async.resolveRequestedRuntime;
pub const Class = class.Class;
pub const ClassWithoutInit = class.ClassWithoutInit;
pub const Buffer = buffer.Buffer;
pub const ArrayBuffer = arraybuffer.ArrayBuffer;
pub const TypedArray = typedarray.TypedArray;
pub const Int8Array = typedarray.Int8Array;
pub const Uint8Array = typedarray.Uint8Array;
pub const Uint8ClampedArray = typedarray.Uint8ClampedArray;
pub const Int16Array = typedarray.Int16Array;
pub const Uint16Array = typedarray.Uint16Array;
pub const Int32Array = typedarray.Int32Array;
pub const Uint32Array = typedarray.Uint32Array;
pub const Float32Array = typedarray.Float32Array;
pub const Float64Array = typedarray.Float64Array;
pub const BigInt64Array = typedarray.BigInt64Array;
pub const BigUint64Array = typedarray.BigUint64Array;
pub const DataView = dataview.DataView;
pub const Reference = reference.Reference;
pub const Ref = reference.Reference;
pub const External = external.External;
pub const NativeWrap = native_wrap;
pub fn FunctionRef(comptime Args: type, comptime Return: type) type {
    return reference.Reference(function.Function(Args, Return));
}
pub const ObjectRef = reference.Reference(value.Object);
pub const Dts = dts_override.Dts;
pub const dts = dts_override.dts;

pub fn globalAllocator() std.mem.Allocator {
    return global_allocator.globalAllocator();
}

/// Explicitly owned native value.
///
/// Conversion results that were allocated natively (for example by
/// `allocator.dupe`) must be returned as `Owned(T)`: the conversion layer
/// converts the payload and then releases it with its own allocator. Plain
/// slices are treated as borrowed and are never freed, so literals and input
/// aliases stay safe.
pub fn Owned(comptime T: type) type {
    return ownership.Owned(T);
}

/// True when `T` is an `napi.Owned` wrapper.
pub fn isOwned(comptime T: type) bool {
    return ownership.isOwned(T);
}

/// Deep-copy a native value shape into memory owned by `allocator`.
/// JavaScript handles are rejected at compile time: they must not become shared
/// state between threads.
pub fn cloneOwned(comptime T: type, source: T, allocator: std.mem.Allocator) !Owned(T) {
    return ownership.Owned(T).clone(source, allocator);
}

/// Override only short-lived conversion/operation allocations.
/// This is mainly useful for scoped allocator tests; applications should use a
/// root `napi_allocator` declaration instead.
pub fn setOperationAllocator(new_allocator: std.mem.Allocator) void {
    global_allocator.global_manager.set(new_allocator);
}

pub fn resetOperationAllocator() void {
    global_allocator.global_manager.set(global_allocator.defaultAllocator());
}

/// Read the operation allocator of the current thread once, so a value that is
/// released later can use exactly the allocator that produced it.
pub fn captureOperationAllocator() std.mem.Allocator {
    return global_allocator.capture();
}

/// Temporarily replace the current thread's operation allocator; the previous
/// one is restored when the scope exits. Overrides are per thread and nest.
pub const ScopedAllocatorOverride = global_allocator.ScopedOverride;

pub fn AsyncContext(comptime Event: type) type {
    return async.AsyncContext(Event);
}
pub fn Async(comptime AsyncResult: type, comptime runtime: async.RuntimeModel) type {
    return async.Async(AsyncResult, runtime);
}
pub fn AsyncWithEvents(comptime AsyncResult: type, comptime Event: type, comptime runtime: async.RuntimeModel) type {
    return async.AsyncWithEvents(AsyncResult, Event, runtime);
}

pub const NODE_API_MODULE = module.NODE_API_MODULE;
pub const NODE_API_MODULE_WITH_INIT = module.NODE_API_MODULE_WITH_INIT;

test {
    // Pull in the native unit tests of the conversion layer so
    // `zig test src/napi.zig` runs them.
    _ = @import("./napi/util/allocator.zig");
    _ = @import("./napi/util/napi.zig");
    _ = @import("./napi/wrapper/error.zig");
    _ = @import("./napi/ownership.zig");
}
