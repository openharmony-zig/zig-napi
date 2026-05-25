const napi = @import("napi");

fn concatWithRustSuffix(value: []const u8) ![]u8 {
    const suffix = " + Rust 🦀 string!";
    const allocator = napi.globalAllocator();
    const out = try allocator.alloc(u8, value.len + suffix.len);
    @memcpy(out[0..value.len], value);
    @memcpy(out[value.len..], suffix);
    return out;
}

pub fn concatString(value: []const u8) ![]u8 {
    return try concatWithRustSuffix(value);
}

pub fn concatUTF16String(value: []const u8) ![]u8 {
    return try concatWithRustSuffix(value);
}

pub fn concatLatin1String(value: []const u8) ![]u8 {
    return try concatWithRustSuffix(value);
}

pub fn createLatin1() []const u8 {
    return "©¿";
}
