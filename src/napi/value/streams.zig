const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Object = @import("object.zig").Object;
const Function = @import("function.zig").Function;
const Value = @import("../value.zig").NapiValue;
const Protocol = @import("protocol.zig");
const PromiseValue = @import("promise.zig").PromiseValue;
const Error = @import("../wrapper/error.zig");

fn hasMethod(env: napi.napi_env, raw: napi.napi_value, name: [:0]const u8) !bool {
    var kind: napi.napi_valuetype = undefined;
    var result: napi.napi_value = null;
    var status = napi.napi_typeof(env, raw, &kind);
    if (status != napi.napi_ok) return Error.failStatus(status);
    if (kind != napi.napi_object) return false;
    status = napi.napi_get_named_property(env, raw, name, &result);
    if (status != napi.napi_ok) return Error.failStatus(status);
    status = napi.napi_typeof(env, result, &kind);
    if (status != napi.napi_ok) return Error.failStatus(status);
    return kind == napi.napi_function;
}

/// Borrowed Web Streams handles. Methods must be called on the environment
/// thread. ReadableStream.New needs the host's ReadableStream constructor;
/// consuming a stream only requires the standard getReader/read protocol.
pub fn ReadableStream(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_kind = "readable-stream";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            return hasMethod(env, raw, "getReader");
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn getReader(self: Self) !ReadableStreamReader(T) {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("getReader", Function(struct {}, ReadableStreamReader(T)))).Apply(object, .{});
        }
        pub fn cancel(self: Self, reason: Value) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("cancel", Function(struct { Value }, PromiseValue))).Apply(object, .{reason});
        }
        /// Moves context into a pull callback. next returns null at EOF. The
        /// host handles backpressure, locks and exceptions from that callback.
        pub fn New(env: Env, context: anytype, comptime next: anytype) !Self {
            const Context = @TypeOf(context);
            const Source = struct {
                context: Context,
                fn pull(self: *@This(), inner: Env, args: struct { Object }) !void {
                    const controller = args[0];
                    if (try next(&self.context, inner)) |item| {
                        try (try controller.Get("enqueue", Function(struct { T }, void))).Apply(controller, .{item});
                    } else {
                        try (try controller.Get("close", Function(struct {}, void))).Apply(controller, .{});
                    }
                }
                fn deinit(self: *@This()) void {
                    if (comptime @typeInfo(Context) == .@"struct" and @hasDecl(Context, "deinit")) self.context.deinit();
                }
            };
            // Check constructor before transferring ownership of context.
            const global = try env.getGlobal();
            const constructor = try global.Get("ReadableStream", Function(struct { Object }, void));
            const source = try Object.Create(env);
            const pull = try Function(struct { Object }, void).NewClosure(env, "pull", Source{ .context = context }, Source.pull);
            try source.Define("pull", pull);
            const stream = try constructor.NewInstance(.{source});
            return from_raw(env.raw, stream.raw);
        }
    };
}

pub fn ReadableStreamReader(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_kind = "readable-stream-reader";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            return hasMethod(env, raw, "read");
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn read(self: Self) !Protocol.PromiseOf(Protocol.Iteration(T)) {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("read", Function(struct {}, Protocol.PromiseOf(Protocol.Iteration(T))))).Apply(object, .{});
        }
        pub fn cancel(self: Self, reason: Value) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("cancel", Function(struct { Value }, PromiseValue))).Apply(object, .{reason});
        }
        pub fn releaseLock(self: Self) !void {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("releaseLock", Function(struct {}, void))).Apply(object, .{});
        }
    };
}

pub fn WritableStream(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_kind = "writable-stream";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            return hasMethod(env, raw, "getWriter");
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn getWriter(self: Self) !WritableStreamWriter(T) {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("getWriter", Function(struct {}, WritableStreamWriter(T)))).Apply(object, .{});
        }
    };
}

pub fn WritableStreamWriter(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_kind = "writable-stream-writer";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            return hasMethod(env, raw, "write");
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn write(self: Self, item: T) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("write", Function(struct { T }, PromiseValue))).Apply(object, .{item});
        }
        pub fn ready(self: Self) !PromiseValue {
            return Object.from_raw(self.env, self.raw).Get("ready", PromiseValue);
        }
        pub fn closed(self: Self) !PromiseValue {
            return Object.from_raw(self.env, self.raw).Get("closed", PromiseValue);
        }
        pub fn close(self: Self) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("close", Function(struct {}, PromiseValue))).Apply(object, .{});
        }
        pub fn abort(self: Self, reason: Value) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("abort", Function(struct { Value }, PromiseValue))).Apply(object, .{reason});
        }
        pub fn releaseLock(self: Self) !void {
            const object = Object.from_raw(self.env, self.raw);
            return (try object.Get("releaseLock", Function(struct {}, void))).Apply(object, .{});
        }
    };
}
