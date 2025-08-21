const CallbackInfo = @import("./callback_info.zig").CallbackInfo;
const Value = @import("../value.zig").Value;

fn CompilerFunction(comptime T: type) type {
    return *const fn (callback_info: CallbackInfo) T;
}

pub const BasicFunction = *const fn () void;
pub const BasicFunctionWithReturn = *const fn () Value;
pub const BasicFunctionWithThrowError = *const fn () anyerror;
pub const BasicFunctionWithReturnAndThrowError = *const fn () anyerror!Value;
pub const BasicFunctionWithCallbackInfo = *const fn (callback_info: CallbackInfo) void;
pub const BasicFunctionWithCallbackInfoAndReturn = *const fn (callback_info: CallbackInfo) Value;
pub const BasicFunctionWithCallbackInfoAndThrowError = *const fn (callback_info: CallbackInfo) anyerror;
pub const BasicFunctionWithCallbackInfoAndReturnAndThrowError = *const fn (callback_info: CallbackInfo) anyerror!Value;

pub const Function = union(enum) {
    Basic: BasicFunction,
    WithReturn: BasicFunctionWithReturn,
    WithError: BasicFunctionWithThrowError,
    WithReturnAndError: BasicFunctionWithReturnAndThrowError,
    WithCallbackInfo: BasicFunctionWithCallbackInfo,
    WithCallbackInfoAndReturn: BasicFunctionWithCallbackInfoAndReturn,
    WithCallbackInfoAndThrowError: BasicFunctionWithCallbackInfoAndThrowError,
    WithCallbackInfoAndReturnAndThrowError: BasicFunctionWithCallbackInfoAndReturnAndThrowError,
};
