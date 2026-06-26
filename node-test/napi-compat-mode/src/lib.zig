const napi = @import("napi");

const napi_version = @import("napi_version.zig");
const array = @import("array.zig");
const arraybuffer = @import("arraybuffer.zig");
const buffer = @import("buffer.zig");
const either = @import("either.zig");
const function = @import("function.zig");
const string = @import("string.zig");
const throw = @import("throw.zig");
const deferred = @import("napi4/deferred.zig");
const threadsafe_function = @import("napi4/threadsafe_function.zig");
const date = @import("napi5/date.zig");
const bigint = @import("napi6/bigint.zig");
const detachable_arraybuffer = @import("napi7/arraybuffer.zig");
const object = @import("napi8/object.zig");

pub const getNapiVersion = napi_version.getNapiVersion;

pub const testCreateArray = array.testCreateArray;
pub const testCreateArrayWithLength = array.testCreateArrayWithLength;
pub const testSetElement = array.testSetElement;
pub const testHasElement = array.testHasElement;
pub const testDeleteElement = array.testDeleteElement;

pub const getArraybufferLength = arraybuffer.getArraybufferLength;
pub const createEmptyArraybufferFromNew = arraybuffer.createEmptyArraybufferFromNew;
pub const createEmptyArraybufferFromData = arraybuffer.createEmptyArraybufferFromData;
pub const createEmptyExternalArraybuffer = arraybuffer.createEmptyExternalArraybuffer;
pub const createExternalArraybuffer = arraybuffer.createExternalArraybuffer;
pub const mutateUint8Array = arraybuffer.mutateUint8Array;
pub const mutateUint16Array = arraybuffer.mutateUint16Array;
pub const mutateInt16Array = arraybuffer.mutateInt16Array;
pub const mutateFloat32Array = arraybuffer.mutateFloat32Array;
pub const mutateFloat64Array = arraybuffer.mutateFloat64Array;

pub const getBufferLength = buffer.getBufferLength;
pub const bufferToString = buffer.bufferToString;
pub const copyBuffer = buffer.copyBuffer;
pub const createBorrowedBufferWithNoopFinalize = buffer.createBorrowedBufferWithNoopFinalize;
pub const createBorrowedBufferWithFinalize = buffer.createBorrowedBufferWithFinalize;
pub const createEmptyBuffer = buffer.createEmptyBuffer;
pub const createEmptyBufferFromNew = buffer.createEmptyBufferFromNew;
pub const createEmptyExternalBuffer = buffer.createEmptyExternalBuffer;
pub const mutateBuffer = buffer.mutateBuffer;

pub const eitherNumberString = either.eitherNumberString;
pub const dynamicArgumentLength = either.dynamicArgumentLength;

pub const testCallFunction = function.testCallFunction;
pub const testCallFunctionWithRefArguments = function.testCallFunctionWithRefArguments;
pub const testCallFunctionError = function.testCallFunctionError;
pub const testCreateFunctionFromClosure = function.testCreateFunctionFromClosure;

pub const concatString = string.concatString;
pub const concatUTF16String = string.concatUTF16String;
pub const concatLatin1String = string.concatLatin1String;
pub const createLatin1 = string.createLatin1;

pub const testThrow = throw.testThrow;
pub const testThrowWithReason = throw.testThrowWithReason;
pub const testThrowWithPanic = throw.testThrowWithPanic;

pub const doubleAsync = deferred.doubleAsync;
pub const callThreadsafeFunction = threadsafe_function.callThreadsafeFunction;

pub const isDate = date.isDate;
pub const createDate = date.createDate;
pub const getDateValue = date.getDateValue;

pub const createBigInt = bigint.createBigInt;
pub const makeBigInt = bigint.makeBigInt;
pub const bigintToI64 = bigint.bigintToI64;
pub const bigintAdd = bigint.bigintAdd;
pub const mutateI64Array = bigint.mutateI64Array;

pub const detachArrayBuffer = detachable_arraybuffer.detachArrayBuffer;
pub const detachArrayBufferLength = detachable_arraybuffer.detachArrayBufferLength;
pub const isDetachedArrayBuffer = detachable_arraybuffer.isDetachedArrayBuffer;

pub const freezeObject = object.freezeObject;
pub const sealObject = object.sealObject;

comptime {
    napi.NODE_API_MODULE("compat_mode", @This());
}
