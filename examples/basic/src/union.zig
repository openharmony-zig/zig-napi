const napi = @import("napi");
const enum_value = @import("enum.zig");

pub const NumberOrText = union(enum) {
    number: f64,
    text: []const u8,
};

const MessagePayload = struct {
    title: []const u8,
    count: f64,
};

pub const ObjectOrText = union(enum) {
    payload: MessagePayload,
    text: []const u8,
};

pub const ObjectOrArray = union(enum) {
    payload: MessagePayload,
    list: []f32,
};

const NamedTuple = struct { f32, bool, []const u8 };

pub const TupleOrText = union(enum) {
    tuple: NamedTuple,
    text: []const u8,
};

pub const FlagOrCount = union(enum) {
    flag: bool,
    count: f64,
};

pub const ColorOrText = union(enum) {
    color: enum_value.Color,
    text: []const u8,
};

pub const MaybeTextOrCount = union(enum) {
    maybe_text: ?[]const u8,
    count: f64,
};

pub const BufferOrText = union(enum) {
    buffer: napi.Buffer,
    text: []const u8,
};

pub const ArrayBufferOrArray = union(enum) {
    arraybuffer: napi.ArrayBuffer,
    list: []const f32,
};

pub const PayloadOrColor = union(enum) {
    payload: MessagePayload,
    color: enum_value.Color,
};

pub const PayloadOrStringColor = union(enum) {
    payload: MessagePayload,
    color: enum_value.StringColor,
};

pub fn union_identity(value: NumberOrText) NumberOrText {
    return value;
}

pub fn make_union(is_number: bool) NumberOrText {
    if (is_number) {
        return .{ .number = 42 };
    }
    return .{ .text = "hello" };
}

pub fn union_kind(value: NumberOrText) []const u8 {
    return switch (value) {
        .number => "number",
        .text => "text",
    };
}

pub fn object_or_text_identity(value: ObjectOrText) ObjectOrText {
    return value;
}

pub fn make_object_or_text(as_object: bool) ObjectOrText {
    if (as_object) {
        return .{ .payload = .{ .title = "hello", .count = 2 } };
    }
    return .{ .text = "plain" };
}

pub fn object_or_array_identity(value: ObjectOrArray) ObjectOrArray {
    return value;
}

pub fn tuple_or_text_identity(value: TupleOrText) TupleOrText {
    return value;
}

pub fn flip_flag_or_increment(value: FlagOrCount) FlagOrCount {
    return switch (value) {
        .flag => |flag| .{ .flag = !flag },
        .count => |count| .{ .count = count + 1 },
    };
}

pub fn color_or_text_identity(value: ColorOrText) ColorOrText {
    return value;
}

pub fn favorite_color_or_text(use_color: bool) ColorOrText {
    if (use_color) {
        return .{ .color = .Blue };
    }
    return .{ .text = "fallback" };
}

pub fn maybe_text_or_count_identity(value: MaybeTextOrCount) MaybeTextOrCount {
    return value;
}

pub fn make_maybe_text_or_count(as_text: bool) MaybeTextOrCount {
    if (as_text) {
        return .{ .maybe_text = null };
    }
    return .{ .count = 7 };
}

pub fn buffer_or_text_identity(value: BufferOrText) BufferOrText {
    return value;
}

pub fn make_buffer_or_text(env: napi.Env, use_buffer: bool) !BufferOrText {
    if (use_buffer) {
        return .{ .buffer = try napi.Buffer.New(env, 16) };
    }
    return .{ .text = "buffer-fallback" };
}

pub fn arraybuffer_or_array_identity(value: ArrayBufferOrArray) ArrayBufferOrArray {
    return value;
}

pub fn make_arraybuffer_or_array(env: napi.Env, use_arraybuffer: bool) !ArrayBufferOrArray {
    if (use_arraybuffer) {
        return .{ .arraybuffer = try napi.ArrayBuffer.New(env, 16) };
    }
    return .{ .list = &[_]f32{ 1, 2, 3 } };
}

pub fn payload_or_color_identity(value: PayloadOrColor) PayloadOrColor {
    return value;
}

pub fn make_payload_or_color(use_payload: bool) PayloadOrColor {
    if (use_payload) {
        return .{ .payload = .{ .title = "mixed", .count = 9 } };
    }
    return .{ .color = .Red };
}

pub fn payload_or_string_color_identity(value: PayloadOrStringColor) PayloadOrStringColor {
    return value;
}

pub fn make_payload_or_string_color(use_payload: bool) PayloadOrStringColor {
    if (use_payload) {
        return .{ .payload = .{ .title = "string-enum", .count = 3 } };
    }
    return .{ .color = .Green };
}
