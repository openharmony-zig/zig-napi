const std = @import("std");
const napi = @import("napi");

const Test = struct {
    name: []u8,
    age: i32,
};

const TestWithInit = struct {
    name: []u8,
    age: i32,

    pub fn init(age: i32, name: []u8) TestWithInit {
        return TestWithInit{ .name = name, .age = age };
    }
};

const TestFactory = struct {
    name: []u8,
    age: i32,

    const Self = @This();

    pub fn initWithFactory(age: i32, name: []u8) Self {
        return TestFactory{ .name = name, .age = age };
    }

    pub fn format(self: *Self) []u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "TestFactory {{ name = {s}, age = {d} }}", .{ self.name, self.age }) catch @panic("OOM");
    }
};

pub const TestClass = napi.Class(Test);
pub const TestWithInitClass = napi.Class(TestWithInit);
pub const TestWithoutInitClass = napi.ClassWithoutInit(TestWithInit);
pub const TestFactoryClass = napi.Class(TestFactory);
