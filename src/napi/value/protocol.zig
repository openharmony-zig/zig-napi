const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Object = @import("object.zig").Object;
const Function = @import("function.zig").Function;
const Value = @import("../value.zig").NapiValue;
const Napi = @import("../util/napi.zig").Napi;
const Error = @import("../wrapper/error.zig");
const PromiseValue = @import("promise.zig").PromiseValue;

pub fn PromiseOf(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const resolved_type = T;
        pub const napi_ts_kind = "promise";
        pub const napi_value_type = T;
        pub const napi_ts_type = "Promise<unknown>";
        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            var result = false;
            const status = napi.napi_is_promise(env, raw, &result);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return result;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn then(self: Self, comptime R: type, callback: Function(struct { T }, R)) !PromiseOf(R) {
            const result = try PromiseValue.from_raw(self.env, self.raw).then(callback);
            return PromiseOf(R).from_raw(self.env, result.raw);
        }
        pub fn catchError(self: Self, callback: anytype) !Self {
            const result = try PromiseValue.from_raw(self.env, self.raw).catchError(callback);
            return from_raw(self.env, result.raw);
        }
        pub fn finally(self: Self, callback: anytype) !Self {
            const result = try PromiseValue.from_raw(self.env, self.raw).finally(callback);
            return from_raw(self.env, result.raw);
        }
    };
}

pub fn Iteration(comptime T: type) type {
    return struct {
        done: bool,
        value: ?T,
        pub const napi_ts_kind = "iteration";
        pub const napi_value_type = T;
    };
}

pub fn Iterator(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_type = "IterableIterator<unknown>";
        pub const napi_ts_kind = "iterator";
        pub const napi_value_type = T;
        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub fn matches_napi_value(env: napi.napi_env, raw: napi.napi_value) !bool {
            var kind: napi.napi_valuetype = undefined;
            var next_: napi.napi_value = null;
            var status = napi.napi_typeof(env, raw, &kind);
            if (status != napi.napi_ok) return Error.failStatus(status);
            if (kind != napi.napi_object) return false;
            status = napi.napi_get_named_property(env, raw, "next", &next_);
            if (status != napi.napi_ok) return Error.failStatus(status);
            status = napi.napi_typeof(env, next_, &kind);
            if (status != napi.napi_ok) return Error.failStatus(status);
            return kind == napi.napi_function;
        }
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn next(self: Self) !Iteration(T) {
            return self.nextWithAllocator(@import("../util/allocator.zig").capture());
        }
        pub fn nextWithAllocator(self: Self, allocator: std.mem.Allocator) !Iteration(T) {
            const object = Object.from_raw(self.env, self.raw);
            const function = try object.Get("next", Function(struct {}, Object));
            const result = try function.Apply(object, .{});
            const done = try result.Get("done", bool);
            // An exhausted iterator need not expose a value property.
            return .{ .done = done, .value = if (done) null else try Napi.from_napi_value_auto_with_allocator(self.env, (try result.Get("value", Value)).raw, T, allocator) };
        }
        pub fn close(self: Self) !void {
            const object = Object.from_raw(self.env, self.raw);
            if (!try object.Has("return")) return;
            const function = try object.Get("return", Function(struct {}, void));
            try function.Apply(object, .{});
        }
        pub fn New(env: Env, context: anytype, comptime next_: anytype) !Self {
            return from_raw(env.raw, try newProducer(T, false, env, context, next_));
        }
    };
}

fn iteratorIdentity(env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
    var receiver: napi.napi_value = null;
    const status = napi.napi_get_cb_info(env, info, null, null, &receiver, null);
    if (status != napi.napi_ok) return null;
    return receiver;
}

pub fn AsyncIterator(comptime T: type) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        pub const napi_custom = true;
        pub const napi_ts_type = "AsyncIterableIterator<unknown>";
        pub const napi_ts_kind = "async-iterator";
        pub const napi_value_type = T;
        const Self = @This();
        pub fn New(env: Env, context: anytype, comptime next_: anytype) !Self {
            return from_raw(env.raw, try newProducer(T, true, env, context, next_));
        }
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return .{ .env = env, .raw = raw };
        }
        pub const matches_napi_value = Iterator(T).matches_napi_value;
        pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, _: std.mem.Allocator) !Self {
            return from_raw(env, raw);
        }
        pub fn to_napi_value(self: Self, _: napi.napi_env) !napi.napi_value {
            return self.raw;
        }
        pub fn next(self: Self) !PromiseOf(Iteration(T)) {
            const object = Object.from_raw(self.env, self.raw);
            const function = try object.Get("next", Function(struct {}, PromiseOf(Iteration(T))));
            return function.Apply(object, .{});
        }
        pub fn close(self: Self) !PromiseValue {
            const object = Object.from_raw(self.env, self.raw);
            if (!try object.Has("return")) {
                var promise = try @import("promise.zig").Promise.New(Env.from_raw(self.env));
                try promise.Resolve(Iteration(T){ .done = true, .value = null });
                return PromiseValue.from_raw(self.env, promise.raw);
            }
            const function = try object.Get("return", Function(struct {}, PromiseValue));
            return function.Apply(object, .{});
        }
    };
}

// All producer methods share one state. Extracted methods keep that state alive;
// return/throw prevent subsequent next calls even if the object itself is gone.
fn newProducer(comptime T: type, comptime async_: bool, env: Env, context: anytype, comptime next_: anytype) !napi.napi_value {
    const Context = @TypeOf(context);
    const Return = if (async_) PromiseOf(Iteration(T)) else Iteration(T);
    const State = struct {
        context: Context,
        allocator: std.mem.Allocator,
        owners: usize = 1,
        closed: bool = false,
        fn release(self: *@This()) void {
            self.owners -= 1;
            if (self.owners != 0) return;
            const allocator = self.allocator;
            if (comptime @typeInfo(Context) == .@"struct" and @hasDecl(Context, "deinit")) self.context.deinit();
            allocator.destroy(self);
        }
    };
    const Handle = struct {
        state: *State,
        fn deinit(self: *@This()) void {
            self.state.release();
        }
        fn finished(inner: Env) !Return {
            const done = Iteration(T){ .done = true, .value = null };
            if (comptime async_) {
                var promise = try @import("promise.zig").Promise.New(inner);
                try promise.Resolve(done);
                return Return.from_raw(inner.raw, promise.raw);
            } else return done;
        }
        fn next(self: *@This(), inner: Env, _: struct {}) !Return {
            if (self.state.closed) return finished(inner);
            const result = try next_(&self.state.context, inner, .{});
            if (comptime !async_) {
                if (result.done) self.state.closed = true;
            }
            return result;
        }
        fn close(self: *@This(), inner: Env, _: struct {}) !Return {
            self.state.closed = true;
            return finished(inner);
        }
        fn throw_(self: *@This(), inner: Env, args: struct { Value }) !Return {
            self.state.closed = true;
            if (comptime async_) {
                var promise = try @import("promise.zig").Promise.New(inner);
                try promise.rejectRaw(args[0].raw);
                return Return.from_raw(inner.raw, promise.raw);
            } else {
                const status = napi.napi_throw(inner.raw, args[0].raw);
                if (status != napi.napi_ok) return Error.failStatus(status);
                return error.PendingException;
            }
        }
    };
    const allocator = @import("../util/allocator.zig").capture();
    const object = try Object.Create(env);
    const state = try allocator.create(State);
    state.* = .{ .context = context, .allocator = allocator };
    const next = Function(struct {}, Return).NewClosure(env, "next", Handle{ .state = state }, Handle.next) catch |err| {
        // NewClosure did not accept ownership of context on failure.
        allocator.destroy(state);
        return err;
    };
    try object.Define("next", next);
    state.owners += 1;
    const close = Function(struct {}, Return).NewClosure(env, "return", Handle{ .state = state }, Handle.close) catch |err| {
        state.release();
        return err;
    };
    try object.Define("return", close);
    state.owners += 1;
    const throw_ = Function(struct { Value }, Return).NewClosure(env, "throw", Handle{ .state = state }, Handle.throw_) catch |err| {
        state.release();
        return err;
    };
    try object.Define("throw", throw_);
    const global = try env.getGlobal();
    const symbols = Object.from_raw(env.raw, (try global.Get("Symbol", Value)).raw);
    const name = if (async_) "asyncIterator" else "iterator";
    const symbol = try symbols.Get(name, Value);
    var identity: napi.napi_value = null;
    const status = napi.napi_create_function(env.raw, name.ptr, name.len, iteratorIdentity, null, &identity);
    if (status != napi.napi_ok) return Error.failStatus(status);
    try object.DefineProperty(symbol, Value.from_raw(env.raw, identity), napi.napi_default_method);
    return object.raw;
}
