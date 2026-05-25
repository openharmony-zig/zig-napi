const napi = @import("napi");

const ArrayInput = union(enum) {
    value: []i32,
};

const TypedArrayInput = union(enum) {
    value: napi.Uint8Array,
};

const BufferInput = union(enum) {
    value: napi.Buffer,
};

const BigIntInput = union(enum) {
    value: napi.BigInt,
};

const BooleanInput = union(enum) {
    value: bool,
};

const FunctionInput = union(enum) {
    value: napi.Function(struct {}, i32),
};

const StringInput = union(enum) {
    value: []const u8,
};

const NullInput = union(enum) {
    value: napi.Null,
};

const UndefinedInput = union(enum) {
    value: napi.Undefined,
};

pub const KindInValidate = enum(u8) {
    Dog = 1,
    Cat = 2,
};

pub const StatusInValidate = enum {
    Ready,
    Poll,

    pub const napi_string_enum = true;
};

const KindInput = union(enum) {
    value: KindInValidate,
};

const StatusInput = union(enum) {
    value: StatusInValidate,
};

pub fn validateArray(input: ArrayInput) usize {
    return input.value.len;
}

pub fn validateTypedArray(input: TypedArrayInput) usize {
    return input.value.length();
}

pub fn validateBuffer(input: BufferInput) usize {
    return input.value.length();
}

pub fn validateBigint(input: BigIntInput) napi.BigInt {
    return input.value;
}

pub fn validateBoolean(input: BooleanInput) bool {
    return !input.value;
}

pub fn validateFunction(input: FunctionInput) !i32 {
    return try input.value.Call(.{});
}

pub fn validateString(input: StringInput) ![]u8 {
    const allocator = napi.globalAllocator();
    const suffix = "!";
    const out = try allocator.alloc(u8, input.value.len + suffix.len);
    @memcpy(out[0..input.value.len], input.value);
    @memcpy(out[input.value.len..], suffix);
    return out;
}

pub fn validateNull(_: NullInput) void {}

pub fn validateUndefined(_: UndefinedInput) void {}

pub fn validateEnum(input: KindInput) KindInValidate {
    return input.value;
}

pub fn validateStringEnum(input: StatusInput) StatusInValidate {
    return input.value;
}

pub fn validateOptional(value: ?[]const u8, default_value: ?bool) bool {
    if (value != null) return true;
    return default_value orelse false;
}
