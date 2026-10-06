const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Object = @import("object.zig").Object;
const Array = @import("array.zig").Array;
const Value = @import("../value.zig").NapiValue;
const Function = @import("function.zig").Function;
const Iterator = @import("protocol.zig").Iterator;
const Napi = @import("../util/napi.zig").Napi;
const Error = @import("../wrapper/error.zig");

pub fn ownKeys(env: Env, object: Object) !Array {
    const global = try env.getGlobal();
    const constructor = Object.from_raw(env.raw, (try global.Get("Object", Value)).raw);
    const keys = try constructor.Get("keys", Function(struct { Object }, Array));
    return keys.Apply(constructor, .{object});
}

/// A native string hash map converted to/from an ordinary JS object's own keys.
pub fn StringMap(comptime V: type) type {
    return struct {
        map: std.StringHashMapUnmanaged(V) = .empty,
        pub const napi_custom = true;
        pub const napi_ts_type = "Record<string, unknown>";
        pub const napi_ts_kind = "record";
        pub const napi_value_type = V;
        const Self = @This();
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            var kind: napi.napi_valuetype = undefined;
            const status = napi.napi_typeof(env, raw, &kind);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return kind == napi.napi_object;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, allocator: std.mem.Allocator) !Self {
            const object = Object.from_raw(env, raw);
            const keys = try ownKeys(Env.from_raw(env), object);
            var result = Self{};
            errdefer result.napi_deinit(allocator);
            for (0..keys.len) |index| {
                const key = try Napi.from_napi_value_auto_with_allocator(env, (try keys.Get(@intCast(index), Value)).raw, []u8, allocator);
                errdefer allocator.free(key);
                const value = try Napi.from_napi_value_auto_with_allocator(env, (try object.Get(key, Value)).raw, V, allocator);
                errdefer Napi.deinit_napi_value_with_allocator(V, value, allocator);
                try result.map.put(allocator, key, value);
            }
            return result;
        }
        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            const object = try Object.Create(Env.from_raw(env));
            var iter = self.map.iterator();
            while (iter.next()) |entry| try object.Define(entry.key_ptr.*, entry.value_ptr.*);
            return object.raw;
        }
        pub fn napi_clone(self: Self, allocator: std.mem.Allocator) !Self {
            var result = Self{};
            errdefer result.napi_deinit(allocator);
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = try Napi.clone_napi_value(V, entry.value_ptr.*, allocator);
                errdefer Napi.deinit_napi_value_with_allocator(V, value, allocator);
                try result.map.put(allocator, key, value);
            }
            return result;
        }
        pub fn napi_deinit(self: Self, allocator: std.mem.Allocator) void {
            var map = self.map;
            var iter = map.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                Napi.deinit_napi_value_with_allocator(V, entry.value_ptr.*, allocator);
            }
            map.deinit(allocator);
        }
    };
}

/// Native values consumed from a JS Set and emitted as a JS Set (deduplicated
/// by the host's SameValueZero rules).
pub fn Set(comptime T: type) type {
    return struct {
        values: std.ArrayList(T) = .empty,
        pub const napi_custom = true;
        pub const napi_ts_type = "Set<unknown>";
        pub const napi_ts_kind = "set";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            var kind: napi.napi_valuetype = undefined;
            const status = napi.napi_typeof(env, raw, &kind);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return kind == napi.napi_object;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, allocator: std.mem.Allocator) !Self {
            const global = try Env.from_raw(env).getGlobal();
            const constructor = Object.from_raw(env, (try global.Get("Set", Value)).raw);
            const prototype = try constructor.Get("prototype", Object);
            // Invoke the intrinsic on the input: this performs a Set brand check
            // even if a plain object supplies its own deceptive values method.
            const method = try prototype.Get("values", Function(struct {}, Iterator(T)));
            const iter = try method.Apply(Value.from_raw(env, raw), .{});
            var result = Self{};
            errdefer result.napi_deinit(allocator);
            while (true) {
                const step = try iter.nextWithAllocator(allocator);
                if (step.done) break;
                const value = step.value.?;
                errdefer Napi.deinit_napi_value_with_allocator(T, value, allocator);
                try result.values.append(allocator, value);
            }
            return result;
        }
        pub fn to_napi_value(self: Self, env: napi.napi_env) !napi.napi_value {
            const global = try Env.from_raw(env).getGlobal();
            const constructor = try global.Get("Set", Function(struct {}, void));
            const object = try constructor.NewInstance(.{});
            const add = try object.Get("add", Function(struct { T }, void));
            for (self.values.items) |value| try add.Apply(object, .{value});
            return object.raw;
        }
        pub fn napi_clone(self: Self, allocator: std.mem.Allocator) !Self {
            var result = Self{};
            errdefer result.napi_deinit(allocator);
            for (self.values.items) |item| {
                const value = try Napi.clone_napi_value(T, item, allocator);
                errdefer Napi.deinit_napi_value_with_allocator(T, value, allocator);
                try result.values.append(allocator, value);
            }
            return result;
        }
        pub fn napi_deinit(self: Self, allocator: std.mem.Allocator) void {
            for (self.values.items) |value| Napi.deinit_napi_value_with_allocator(T, value, allocator);
            var list = self.values;
            list.deinit(allocator);
        }
    };
}

/// Owned recursive JSON tree. Its arena is stable across wrapper moves; JS
/// handles never escape the conversion. Cycles and non-JSON values are errors.
pub const Json = struct {
    value: std.json.Value,
    arena: *std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    pub const napi_custom = true;
    pub const napi_ts_type = "unknown";
    pub fn matches_napi_value(_: napi.napi_env, _: napi.napi_value) !bool {
        return true;
    }
    pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, backing: std.mem.Allocator) !Json {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = .init(backing);
        errdefer {
            arena.deinit();
            backing.destroy(arena);
        }
        var ancestors: [256]napi.napi_value = undefined;
        return .{ .value = try read(env, raw, arena.allocator(), &ancestors, 0), .arena = arena, .backing = backing };
    }
    fn read(env: napi.napi_env, raw: napi.napi_value, allocator: std.mem.Allocator, ancestors: *[256]napi.napi_value, depth: usize) anyerror!std.json.Value {
        if (depth == ancestors.len) return Error.failRangeError("JSON nesting exceeds {d}", .{ancestors.len});
        var kind: napi.napi_valuetype = undefined;
        const status = napi.napi_typeof(env, raw, &kind);
        if (status != napi.napi_ok) return Error.failStatus(status);
        switch (kind) {
            napi.napi_null => return .null,
            napi.napi_boolean => return .{ .bool = try Napi.from_napi_value_auto(env, raw, bool) },
            napi.napi_number => {
                const number = try Napi.from_napi_value_auto(env, raw, f64);
                if (!std.math.isFinite(number)) return Error.failTypeError("JSON numbers must be finite", .{});
                return .{ .float = number };
            },
            napi.napi_string => return .{ .string = try Napi.from_napi_value_auto_with_allocator(env, raw, []u8, allocator) },
            napi.napi_object => {
                for (ancestors[0..depth]) |ancestor| {
                    var same = false;
                    const equal_status = napi.napi_strict_equals(env, ancestor, raw, &same);
                    if (equal_status != napi.napi_ok) return Error.failStatus(equal_status);
                    if (same) return Error.failTypeError("Cannot convert cyclic JSON", .{});
                }
                ancestors[depth] = raw;
                var is_array = false;
                const array_status = napi.napi_is_array(env, raw, &is_array);
                if (array_status != napi.napi_ok) return Error.failStatus(array_status);
                if (is_array) {
                    const source = Array.from_raw(env, raw);
                    var items = std.json.Array.init(allocator);
                    for (0..source.len) |index| try items.append(try read(env, (try source.Get(@intCast(index), Value)).raw, allocator, ancestors, depth + 1));
                    return .{ .array = items };
                }
                const source = Object.from_raw(env, raw);
                const keys = try ownKeys(Env.from_raw(env), source);
                var object: std.json.ObjectMap = .{};
                for (0..keys.len) |index| {
                    const key = try Napi.from_napi_value_auto_with_allocator(env, (try keys.Get(@intCast(index), Value)).raw, []u8, allocator);
                    const child = try read(env, (try source.Get(key, Value)).raw, allocator, ancestors, depth + 1);
                    try object.put(allocator, key, child);
                }
                return .{ .object = object };
            },
            else => return Error.failTypeError("Value is not JSON-compatible", .{}),
        }
    }
    fn write(env: napi.napi_env, value: std.json.Value) anyerror!napi.napi_value {
        return switch (value) {
            .null => Napi.to_napi_value_auto(env, null, null),
            .bool => |v| Napi.to_napi_value_auto(env, v, null),
            .integer => |v| Napi.to_napi_value_auto(env, v, null),
            .float => |v| Napi.to_napi_value_auto(env, v, null),
            .string => |v| Napi.to_napi_value_auto(env, v, null),
            .number_string => |v| Napi.to_napi_value_auto(env, try std.fmt.parseFloat(f64, v), null),
            .array => |v| blk: {
                var raw: napi.napi_value = null;
                const status = napi.napi_create_array_with_length(env, v.items.len, &raw);
                if (status != napi.napi_ok) return Error.failStatus(status);
                for (v.items, 0..) |child, i| {
                    const set_status = napi.napi_set_element(env, raw, @intCast(i), try write(env, child));
                    if (set_status != napi.napi_ok) return Error.failStatus(set_status);
                }
                break :blk raw;
            },
            .object => |v| blk: {
                const object = try Object.Create(Env.from_raw(env));
                var iter = v.iterator();
                while (iter.next()) |entry| try object.Define(entry.key_ptr.*, Value.from_raw(env, try write(env, entry.value_ptr.*)));
                break :blk object.raw;
            },
        };
    }
    pub fn to_napi_value(self: Json, env: napi.napi_env) !napi.napi_value {
        return write(env, self.value);
    }
    pub fn napi_clone(self: Json, backing: std.mem.Allocator) !Json {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = .init(backing);
        errdefer {
            arena.deinit();
            backing.destroy(arena);
        }
        return .{ .value = try cloneJson(self.value, arena.allocator()), .arena = arena, .backing = backing };
    }
    fn cloneJson(value: std.json.Value, allocator: std.mem.Allocator) anyerror!std.json.Value {
        return switch (value) {
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
            .array => |items| blk: {
                var cloned = std.json.Array.init(allocator);
                for (items.items) |item| try cloned.append(try cloneJson(item, allocator));
                break :blk .{ .array = cloned };
            },
            .object => |object| blk: {
                var cloned: std.json.ObjectMap = .{};
                var iter = object.iterator();
                while (iter.next()) |entry| try cloned.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJson(entry.value_ptr.*, allocator));
                break :blk .{ .object = cloned };
            },
            else => value,
        };
    }
    pub fn napi_deinit(self: Json, _: std.mem.Allocator) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }
};
