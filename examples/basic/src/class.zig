const napi = @import("napi");

const Test = struct {
    name: []u8,
    age: i32,
};

pub const TestClass = napi.Class(Test);
