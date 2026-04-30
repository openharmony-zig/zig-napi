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

pub const napi_sys = @import("napi-sys");
pub const Env = env.Env;
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
pub fn FunctionRef(comptime Args: type, comptime Return: type) type {
    return reference.Reference(function.Function(Args, Return));
}
pub const ObjectRef = reference.Reference(value.Object);
pub fn AsyncContext(comptime Event: type) type {
    return async.AsyncContext(Event);
}
pub fn Async(comptime Result: type, comptime runtime: async.RuntimeModel) type {
    return async.Async(Result, runtime);
}
pub fn AsyncWithEvents(comptime Result: type, comptime Event: type, comptime runtime: async.RuntimeModel) type {
    return async.AsyncWithEvents(Result, Event, runtime);
}

pub const NODE_API_MODULE = module.NODE_API_MODULE;
pub const NODE_API_MODULE_WITH_INIT = module.NODE_API_MODULE_WITH_INIT;
