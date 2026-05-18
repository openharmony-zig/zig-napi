const napi = @import("napi");

const ZigBenchData = struct {
    value: i32,

    pub fn init(value: i32) ZigBenchData {
        return .{ .value = value };
    }

    pub fn add(self: *ZigBenchData, delta: i32) i32 {
        self.value += delta;
        return self.value;
    }
};

pub const ZigBenchClass = napi.Class(ZigBenchData);

pub fn zig_noop() void {}

pub fn zig_add_i32(left: i32, right: i32) i32 {
    return left + right;
}

pub fn zig_bool_identity(value: bool) bool {
    return value;
}

pub fn zig_string_len(value: napi.String) usize {
    return value.utf8Len();
}

pub fn zig_object_read(value: napi.Object) i32 {
    const count = value.GetNamed("count", i32);
    const flag = value.GetNamed("flag", bool);
    return count + if (flag) @as(i32, 1) else 0;
}

pub fn zig_array_sum(values: napi.Array) f64 {
    var total: f64 = 0;
    for (0..values.length()) |i| {
        total += values.Get(@intCast(i), f64);
    }
    return total;
}

pub fn zig_call_function(cb: napi.Function(struct { i32, i32 }, i32)) !i32 {
    return try cb.Call(.{ 19, 23 });
}

pub fn zig_new_arraybuffer(env: napi.Env, len: u32) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.New(env, len);
}

pub fn zig_arraybuffer_length(value: napi.ArrayBuffer) usize {
    return value.length();
}

pub fn zig_new_buffer(env: napi.Env, len: u32) !napi.Buffer {
    return try napi.Buffer.New(env, len);
}

pub fn zig_buffer_length(value: napi.Buffer) usize {
    return value.length();
}

pub fn zig_new_uint8array(env: napi.Env, len: u32) !napi.Uint8Array {
    return try napi.Uint8Array.New(env, len);
}

pub fn zig_uint8array_sum(value: napi.Uint8Array) usize {
    var total: usize = 0;
    for (value.asConstSlice()) |item| {
        total += item;
    }
    return total;
}

pub fn zig_new_dataview(env: napi.Env, len: u32) !napi.DataView {
    return try napi.DataView.New(env, len);
}

pub fn zig_dataview_length(value: napi.DataView) usize {
    return value.byteLength();
}

comptime {
    napi.NODE_API_MODULE("zig_benchmark", @This());
}
