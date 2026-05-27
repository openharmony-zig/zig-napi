const napi = @import("napi");

pub const ExternalPoint = struct {
    x: i32,
    y: i32,
};

pub fn create_external(value: u32) !napi.External(u32) {
    return try napi.External(u32).New(value);
}

pub fn create_external_with_size_hint(value: u32) !napi.External(u32) {
    return try napi.External(u32).NewWithSizeHint(value, 128);
}

pub fn get_external(external: napi.External(u32)) u32 {
    return external.value().*;
}

pub fn get_external_size_hint(external: napi.External(u32)) usize {
    return external.sizeHint();
}

pub fn mutate_external(external: napi.External(u32), value: u32) void {
    external.valueMut().* = value;
}

pub fn create_external_point(x: i32, y: i32) !napi.External(ExternalPoint) {
    return try napi.External(ExternalPoint).New(.{ .x = x, .y = y });
}

pub fn get_external_point(external: napi.External(ExternalPoint)) ExternalPoint {
    return external.value().*;
}

pub fn mutate_external_point(external: napi.External(ExternalPoint), x: i32, y: i32) void {
    external.valueMut().* = .{ .x = x, .y = y };
}
