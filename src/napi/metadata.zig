const std = @import("std");
pub const MemberKind = enum { method, getter, setter };
pub const WellKnownSymbol = enum {
    iterator,
    asyncIterator,
    hasInstance,
    isConcatSpreadable,
    match,
    matchAll,
    replace,
    search,
    species,
    split,
    toPrimitive,
    toStringTag,
    unscopables,
    dispose,
    asyncDispose,
};
pub const ClassSymbol = union(enum) { registry: []const u8, well_known: WellKnownSymbol };
pub const ExportOptions = struct {
    symbol: ?ClassSymbol = null,
    name: ?[:0]const u8 = null,
    namespace: ?[:0]const u8 = null,
    skip: bool = false,
    readonly: bool = false,
    nullable: bool = false,
    attributes: ?u32 = null,
    kind: MemberKind = .method,
};

/// Declare pub const napi_config = .{ .member = napi.ExportOptions{ ... } }.
/// Runtime exports and declarations read the same metadata.
pub fn get(comptime T: type, comptime member: []const u8) ExportOptions {
    if (!@hasDecl(T, "napi_config")) return .{};
    const config = T.napi_config;
    if (!@hasField(@TypeOf(config), member)) return .{};
    return @field(config, member);
}
pub fn name(comptime T: type, comptime member: []const u8) [:0]const u8 {
    return get(T, member).name orelse (member ++ "")[0..member.len :0];
}
pub fn reserved(comptime member: []const u8) bool {
    return std.mem.eql(u8, member, "napi_config") or std.mem.eql(u8, member, "napi_allocator") or std.mem.eql(u8, member, "arg_ownership");
}

/// Registry symbols have runtime identity and cannot be named as TypeScript
/// unique symbols. Well-known symbols have standard computed property names.
pub fn classDeclarationName(comptime T: type, comptime member: []const u8) ?[]const u8 {
    return if (get(T, member).symbol) |key| switch (key) {
        .registry => null,
        .well_known => |symbol| "[globalThis.Symbol." ++ @tagName(symbol) ++ "]",
    } else name(T, member);
}
