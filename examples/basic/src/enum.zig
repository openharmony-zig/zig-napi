pub const Color = enum(i32) {
    Red = 1,
    Green = 2,
    Blue = 4,
};

pub fn enum_identity(color: Color) Color {
    return color;
}

pub fn favorite_color() Color {
    return .Green;
}

pub fn is_primary(color: Color) bool {
    return switch (color) {
        .Red, .Green, .Blue => true,
    };
}

pub const StringColor = enum {
    Red,
    Green,
    Blue,

    pub const napi_string_enum = true;
};

pub fn string_enum_identity(color: StringColor) StringColor {
    return color;
}

pub fn favorite_string_color() StringColor {
    return .Blue;
}
