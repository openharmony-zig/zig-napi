const napi = @import("napi");

pub fn parityStringLengths(value: napi.String) !struct { utf8: usize, utf16: usize, latin1: usize } {
    return .{ .utf8 = try value.utf8Len(), .utf16 = try value.utf16Len(), .latin1 = try value.latin1Len() };
}

pub fn parityLatin1(env: napi.Env, value: napi.String) !napi.String {
    const bytes = try value.copyLatin1();
    defer napi.globalAllocator().free(bytes);
    return napi.String.createLatin1(env, bytes);
}

pub fn parityObject() struct { x: i32, __proto__: i32 } {
    return .{ .x = 42, .__proto__ = 7 };
}

pub fn parityApply(callback: napi.Function(struct { i32 }, i32), receiver: napi.Object, value: i32) !i32 {
    return callback.Apply(receiver, .{value});
}

pub fn parityBind(callback: napi.Function(struct { i32 }, i32), receiver: napi.Object) !napi.Function(struct { i32 }, i32) {
    return callback.Bind(receiver);
}

pub fn parityConstruct(callback: napi.Function(struct { i32 }, void), value: i32) !napi.Object {
    return callback.NewInstance(.{value});
}

pub fn parityFunctionName(callback: napi.Function(struct {}, void)) !napi.String {
    return callback.name();
}

pub fn parityClosure(env: napi.Env, initial: i32) !napi.Function(struct { i32 }, i32) {
    const State = struct {
        total: i32,
        fn call(self: *@This(), _: napi.Env, args: struct { i32 }) !i32 {
            self.total += args[0];
            return self.total;
        }
    };
    return napi.Function(struct { i32 }, i32).NewClosure(env, "accumulate", State{ .total = initial }, State.call);
}

pub fn parityScope(env: napi.Env) !napi.NapiValue {
    var scope = try napi.EscapableHandleScope.open(env);
    defer scope.close() catch @panic("scope close failed");
    const value = try napi.String.createUtf8(env, "escaped");
    return scope.escape(value);
}

pub fn parityScript(env: napi.Env, source: []const u8) !napi.NapiValue {
    return env.runScript(source, napi.NapiValue);
}

pub fn parityPromise(value: napi.PromiseOf(i32), callback: napi.Function(struct { i32 }, i32)) !napi.PromiseOf(i32) {
    return value.then(i32, callback);
}
pub fn parityPromiseCatch(value: napi.PromiseValue, callback: napi.Function(struct { napi.NapiValue }, i32)) !napi.PromiseValue {
    return value.catchError(callback);
}
pub fn parityPromiseFinally(value: napi.PromiseValue, callback: napi.Function(struct {}, void)) !napi.PromiseValue {
    return value.finally(callback);
}
pub fn parityMap(value: napi.StringMap([]u8)) napi.StringMap([]u8) {
    return value;
}
pub fn paritySet(value: napi.Set(i32)) napi.Set(i32) {
    return value;
}
pub fn parityJson(value: napi.Json) napi.Json {
    return value;
}
pub fn parityIterator(env: napi.Env, count: i32) !napi.Iterator(i32) {
    const State = struct {
        index: i32 = 0,
        count: i32,
        fn next(self: *@This(), _: napi.Env, _: struct {}) !napi.Iteration(i32) {
            if (self.index >= self.count) return .{ .done = true, .value = null };
            const value = self.index;
            self.index += 1;
            return .{ .done = false, .value = value };
        }
    };
    return napi.Iterator(i32).New(env, State{ .count = count }, State.next);
}
pub fn parityIteratorSum(value: napi.Iterator(i32)) !i32 {
    var sum: i32 = 0;
    while (true) {
        const next = try value.next();
        if (next.done) break;
        sum += next.value.?;
    }
    return sum;
}
pub fn parityAsyncIteratorNext(value: napi.AsyncIterator(i32)) !napi.PromiseOf(napi.Iteration(i32)) {
    return value.next();
}

const RetTsfn = napi.ThreadSafeFunction(struct { i32 }, i32, false, 0);
pub fn parityTsfnAsync(callback: *RetTsfn, value: i32) !napi.Promise {
    const promise = try callback.CallAsync(.{value}, .NonBlocking);
    try callback.release(.Release);
    return promise;
}
const PromiseTsfn = napi.ThreadSafeFunction(struct { i32 }, napi.PromiseValue, false, 0);
pub fn parityTsfnPromise(callback: *PromiseTsfn, value: i32) !napi.Promise {
    const promise = try callback.CallAsync(.{value}, .NonBlocking);
    try callback.release(.Release);
    return promise;
}
pub fn parityTsfnBuilder(env: napi.Env, callback: napi.Function(struct { i32 }, i32)) !napi.Object {
    const tsfn = try RetTsfn.builder(env, callback).weak(true).maxQueueSize(1).build();
    defer tsfn.release(.Release) catch {};
    const first = try tsfn.CallAsyncCatch(.{21}, .NonBlocking);
    const second = try tsfn.CallAsync(.{1}, .NonBlocking);
    return napi.Object.New(env, .{ .first = first, .second = second });
}

const BoundedTsfn = napi.ThreadSafeFunction(struct { i32 }, void, false, 1);
pub fn parityTsfnBlocking(env: napi.Env, callback: napi.Function(struct { i32 }, void)) !void {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.NativeThreadRequired;
    const tsfn = try BoundedTsfn.builder(env, callback).build();
    errdefer tsfn.abort() catch {};
    try tsfn.Ok(.{1}, .NonBlocking);
    const Worker = struct {
        fn run(handle: *BoundedTsfn) void {
            defer handle.release(.Release) catch {};
            handle.Ok(.{2}, .Blocking) catch return;
            handle.Ok(.{3}, .Blocking) catch return;
        }
    };
    const thread = try @import("std").Thread.spawn(.{}, Worker.run, .{tsfn});
    thread.detach();
}

pub fn parityTsfnAbort(env: napi.Env, callback: napi.Function(struct { i32 }, void)) !bool {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.NativeThreadRequired;
    const std = @import("std");
    const tsfn = try BoundedTsfn.builder(env, callback).build();
    errdefer tsfn.abort() catch {};
    try tsfn.Ok(.{1}, .NonBlocking);
    try tsfn.acquire();
    const Worker = struct {
        handle: *BoundedTsfn,
        started: std.atomic.Value(bool) = .init(false),
        closed: bool = false,
        fn run(self: *@This()) void {
            defer self.handle.release(.Release) catch {};
            self.started.store(true, .release);
            self.handle.Ok(.{2}, .Blocking) catch |err| {
                self.closed = err == error.Closing;
            };
        }
    };
    var worker = Worker{ .handle = tsfn };
    const thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |err| {
        try tsfn.release(.Release);
        return err;
    };
    while (!worker.started.load(.acquire)) std.atomic.spinLoopHint();
    // The event-loop thread holds the first slot throughout this call.
    // Abort must wake the blocked native producer before it can be joined.
    try tsfn.abort();
    thread.join();
    return worker.closed;
}
pub const ParityCounter = struct {
    value: i32,
    pub fn init(value: i32) @This() {
        return .{ .value = value };
    }
};
pub fn parityClassInstance(instance: napi.ClassInstance(ParityCounter), amount: i32) i32 {
    instance.value.value += amount;
    return instance.value.value;
}

pub fn parityShared(env: napi.Env, object: napi.Object) !napi.Object {
    const reference = try napi.SharedReference(napi.Object).New(env, object);
    const alias = try reference.Clone();
    reference.Close();
    defer alias.Close();
    const weak = try alias.downgrade();
    defer weak.Close();
    const upgraded = (try weak.upgrade()).?;
    defer upgraded.Close();
    return upgraded.GetValue();
}

pub fn parityDate(env: napi.Env, date: napi.Date) !napi.Date {
    return napi.Date.New(env, try date.value());
}
pub const MetadataObject = struct {
    value: i32,
    missing: ?i32,
    internal: []const u8 = "borrowed",
    pub const napi_config = .{
        .value = napi.ExportOptions{ .name = "count", .readonly = true },
        .missing = napi.ExportOptions{ .nullable = true },
        .internal = napi.ExportOptions{ .skip = true },
    };
};
pub fn parityMetadataObject(value: MetadataObject) MetadataObject {
    return value;
}
const TaggedPayload = union(enum) { first: struct { count: i32 }, second: struct { count: i32 }, text: []u8 };
pub fn parityTagged(value: napi.TaggedUnion(TaggedPayload, "kind", "data")) napi.TaggedUnion(TaggedPayload, "kind", "data") {
    return value;
}
pub fn paritySymbol(env: napi.Env, symbol: napi.Symbol) !napi.Object {
    const unique = try napi.Symbol.New(env, "unique");
    return napi.Object.New(env, .{ .input = symbol, .unique = unique });
}
pub fn parityThis(receiver: napi.This(struct { base: i32 }), value: i32) i32 {
    return receiver.value.base + value;
}
pub fn parityAsyncGenerator(env: napi.Env, count: i32) !napi.AsyncIterator(i32) {
    const State = struct {
        index: i32 = 0,
        count: i32,
        fn execute(iteration: napi.Iteration(i32)) napi.Iteration(i32) {
            return iteration;
        }
        fn next(self: *@This(), inner_env: napi.Env, _: struct {}) !napi.PromiseOf(napi.Iteration(i32)) {
            const iteration: napi.Iteration(i32) = if (self.index >= self.count) .{ .done = true, .value = null } else .{ .done = false, .value = self.index };
            self.index += 1;
            var task = napi.Async(napi.Iteration(i32), .single).from(iteration, execute);
            const promise = try task.schedule(inner_env);
            return napi.PromiseOf(napi.Iteration(i32)).from_raw(inner_env.raw, promise.raw);
        }
    };
    return napi.AsyncIterator(i32).New(env, State{ .count = count }, State.next);
}

pub const MetadataCounter = struct {
    value: i32,
    secret: i32 = 7,
    pub const napi_config = .{
        .value = napi.ExportOptions{ .name = "count", .readonly = true },
        .secret = napi.ExportOptions{ .skip = true },
        .increment = napi.ExportOptions{ .name = "add", .attributes = 2 | 4 },
        .getDouble = napi.ExportOptions{ .name = "double", .kind = .getter },
        .setDouble = napi.ExportOptions{ .name = "double", .kind = .setter },
    };
    pub fn init(value: i32) @This() {
        return .{ .value = value };
    }
    pub fn increment(self: *@This(), value: i32) i32 {
        self.value += value;
        return self.value;
    }
    pub fn getDouble(self: *@This()) i32 {
        return self.value * 2;
    }
    pub fn setDouble(self: *@This(), value: i32) void {
        self.value = @divTrunc(value, 2);
    }
};

pub fn parityReadable(stream: napi.ReadableStream(i32)) !napi.ReadableStreamReader(i32) {
    return stream.getReader();
}
pub fn parityRead(reader: napi.ReadableStreamReader(i32)) !napi.PromiseOf(napi.Iteration(i32)) {
    return reader.read();
}
pub fn parityReaderCancel(reader: napi.ReadableStreamReader(i32), reason: napi.NapiValue) !napi.PromiseValue {
    return reader.cancel(reason);
}
pub fn parityReaderRelease(reader: napi.ReadableStreamReader(i32)) !void {
    return reader.releaseLock();
}
pub fn parityWritable(stream: napi.WritableStream(i32)) !napi.WritableStreamWriter(i32) {
    return stream.getWriter();
}
pub fn parityWrite(writer: napi.WritableStreamWriter(i32), value: i32) !napi.PromiseValue {
    return writer.write(value);
}
pub fn parityWriterClose(writer: napi.WritableStreamWriter(i32)) !napi.PromiseValue {
    return writer.close();
}
pub fn parityWriterAbort(writer: napi.WritableStreamWriter(i32), reason: napi.NapiValue) !napi.PromiseValue {
    return writer.abort(reason);
}
pub fn parityWriterRelease(writer: napi.WritableStreamWriter(i32)) !void {
    return writer.releaseLock();
}
pub fn parityNativeReadable(env: napi.Env, count: i32) !napi.ReadableStream(i32) {
    const State = struct {
        index: i32 = 0,
        count: i32,
        fn next(self: *@This(), _: napi.Env) !?i32 {
            if (self.index >= self.count) return null;
            const value = self.index;
            self.index += 1;
            return value;
        }
    };
    return napi.ReadableStream(i32).New(env, State{ .count = count }, State.next);
}

pub fn paritySharedThread(env: napi.Env, object: napi.Object) !napi.Object {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.NativeThreadRequired;
    const reference = try napi.SharedReference(napi.Object).New(env, object);
    const retained = try reference.Clone();
    const Thread = struct {
        fn run(value: napi.SharedReference(napi.Object)) void {
            const copy = value.Clone() catch @panic("reference clone failed");
            value.Close();
            copy.Close();
        }
    };
    const thread = @import("std").Thread.spawn(.{}, Thread.run, .{reference}) catch |err| {
        reference.Close();
        retained.Close();
        return err;
    };
    thread.join();
    const result = try retained.GetValue();
    // Transfer the final owner to a second thread to exercise actual disposal.
    const last = @import("std").Thread.spawn(.{}, Thread.run, .{retained}) catch |err| {
        retained.Close();
        return err;
    };
    last.join();
    return result;
}

pub fn parityFeatureVersion() u32 {
    return @intCast(@intFromEnum(napi.selectedNapiVersion()));
}
pub fn parityExternalLatin1(env: napi.Env, value: napi.String) !napi.String.ExternalResult {
    const bytes = try value.copyLatin1();
    defer napi.captureOperationAllocator().free(bytes);
    return napi.String.createExternalLatin1(env, bytes);
}
pub fn parityExternalUtf16(env: napi.Env, value: []u16) !napi.String.ExternalResult {
    return napi.String.createExternalUtf16(env, value);
}
pub fn parityEnvironment(env: napi.Env) !struct { stored: bool, replacement_rejected: bool, async_removed: bool } {
    const State = struct {
        value: i32 = 42,
        fn finalizer(_: napi.napi_sys.napi_sys.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            napi.safePageAllocator().destroy(@as(*@This(), @ptrCast(@alignCast(data.?))));
        }
        fn cleanup(_: ?*anyopaque) callconv(.c) void {}
        fn asyncCleanup(handle: napi.napi_sys.napi_sys.napi_async_cleanup_hook_handle, _: ?*anyopaque) callconv(.c) void {
            var hook = napi.AsyncCleanupHook{ .raw = handle };
            hook.remove() catch @panic("cleanup hook remove failed");
        }
    };
    if ((try env.getInstanceData(State)) == null) {
        const state = try napi.safePageAllocator().create(State);
        errdefer napi.safePageAllocator().destroy(state);
        state.* = .{};
        try env.setInstanceData(state, State.finalizer, null);
    }
    const state = (try env.getInstanceData(State)).?;
    const rejected = if (env.setInstanceData(state, State.finalizer, null)) |_| false else |err| err == error.InstanceDataAlreadySet;
    try env.addCleanupHook(State.cleanup, null);
    try env.removeCleanupHook(State.cleanup, null);
    var hook = try env.addAsyncCleanupHook(State.asyncCleanup, null);
    try hook.remove();
    try hook.remove();
    _ = try env.adjustExternalMemory(1024);
    _ = try env.adjustExternalMemory(-1024);
    return .{ .stored = state.value == 42, .replacement_rejected = rejected, .async_removed = hook.raw == null };
}

pub const NamespacedCounter = struct {
    value: i32,
    pub fn init(value: i32) @This() {
        return .{ .value = value };
    }
};
pub fn parityNamespaced(instance: napi.ClassInstance(NamespacedCounter)) i32 {
    return instance.value.value;
}

pub fn parityAsyncMap(value: napi.StringMap([]u8)) napi.Async(napi.StringMap([]u8), .thread) {
    const Task = struct {
        fn execute(input: napi.StringMap([]u8)) napi.StringMap([]u8) {
            return input;
        }
    };
    return .from(value, Task.execute);
}
pub fn parityAsyncJson(value: napi.Json) napi.Async(napi.Json, .thread) {
    const Task = struct {
        fn execute(input: napi.Json) napi.Json {
            return input;
        }
    };
    return .from(value, Task.execute);
}

const WeakClosure = napi.Function(struct {}, ?napi.Object);
pub fn parityWeakClosure(env: napi.Env, object: napi.Object) !WeakClosure {
    const State = struct {
        reference: napi.WeakReference(napi.Object),
        fn call(self: *@This(), _: napi.Env, _: struct {}) !?napi.Object {
            return self.reference.Get();
        }
        fn deinit(self: *@This()) void {
            self.reference.Close();
        }
    };
    const reference = try napi.WeakReference(napi.Object).New(env, object);
    errdefer reference.Close();
    return WeakClosure.NewClosure(env, "getWeak", State{ .reference = reference }, State.call);
}

pub fn parityAwaitPromise(value: napi.NativePromise(i32)) napi.Async(i32, .thread) {
    const Task = struct {
        fn execute(context: napi.AsyncContext(void), input: napi.NativePromise(i32)) !i32 {
            return (try input.wait(context.io)) * 2;
        }
    };
    return .from(value, Task.execute);
}

pub fn paritySymbolFor(env: napi.Env, key: []const u8) !napi.Symbol {
    return env.symbolFor(key);
}

pub const ParityFactory = struct {
    value: i32,
    pub fn create(value: i32) @This() {
        return .{ .value = value };
    }
};
pub fn parityFactoryInstance(instance: napi.FactoryClassInstance(ParityFactory)) i32 {
    return instance.value.value;
}
