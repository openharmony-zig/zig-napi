const build_options = @import("build_options");

fn isTypeDefinitionBuild() bool {
    return @hasDecl(build_options, "napi_tsgen") and build_options.napi_tsgen;
}

fn isComptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn", .type, .comptime_int, .comptime_float, .enum_literal => true,
        else => false,
    };
}

fn DtsWrapper(comptime Value: type, comptime TypeScriptType: []const u8) type {
    if (comptime isComptimeOnly(Value)) {
        return struct {
            pub const is_napi_dts = true;
            pub const wrapped_type = Value;
            pub const ts_type = TypeScriptType;

            const Self = @This();

            pub fn unwrap(comptime _: Self) Value {
                @compileError("Type-only dts wrappers do not carry comptime-only values");
            }
        };
    }

    return struct {
        pub const is_napi_dts = true;
        pub const wrapped_type = Value;
        pub const ts_type = TypeScriptType;

        value: Value,

        const Self = @This();

        pub fn unwrap(self: Self) Value {
            return self.value;
        }
    };
}

pub fn Dts(comptime Value: type, comptime TypeScriptType: []const u8) type {
    if (comptime !isTypeDefinitionBuild()) return Value;
    return DtsWrapper(Value, TypeScriptType);
}

pub fn dts(value: anytype, comptime TypeScriptType: []const u8) Dts(@TypeOf(value), TypeScriptType) {
    if (comptime isTypeDefinitionBuild()) {
        if (comptime !@hasField(Dts(@TypeOf(value), TypeScriptType), "value")) {
            return .{};
        }
        return .{ .value = value };
    }
    return value;
}
