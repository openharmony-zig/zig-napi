const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const math = std.math;

pub const StringMode = enum {
    Utf8,
    Utf16,
    Unknown,
};

pub fn stringLike(comptime T: type) StringMode {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            const child_info = @typeInfo(ptr.child);
            switch (child_info) {
                .array => |arr| {
                    switch (arr.child) {
                        u8 => return StringMode.Utf8,
                        u16 => return StringMode.Utf16,
                        else => return StringMode.Unknown,
                    }
                },
                .int => |int| {
                    switch (int.bits) {
                        8 => return StringMode.Utf8,
                        16 => return StringMode.Utf16,
                        else => return StringMode.Unknown,
                    }
                },
                else => return StringMode.Unknown,
            }
        },
        .array => |arr| {
            switch (arr.child) {
                u8 => return StringMode.Utf8,
                u16 => return StringMode.Utf16,
                else => return StringMode.Unknown,
            }
        },
        else => return StringMode.Unknown,
    }
}

pub fn isTuple(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".is_tuple;
}

pub fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

pub fn isSinglePointer(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .one;
}

pub fn isNapiFunction(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        return false;
    }
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "inner_fn")) {
            return true;
        }
    }
    return false;
}

pub fn isThreadSafeFunction(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        return false;
    }
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "tsfn_raw")) {
            return true;
        }
    }
    return false;
}

pub fn isAsyncDescriptor(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_async_descriptor");
}

pub fn isAbortSignal(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_abort_signal");
}

pub fn isTypedArray(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_typedarray");
}

pub fn isDataView(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_dataview");
}

pub fn isReference(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_reference");
}

pub fn isExternal(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_external");
}

pub fn isFixedArray(comptime T: type) bool {
    return @typeInfo(T) == .array;
}

/// True when `T` is a `napi.Owned` wrapper.
pub fn isOwned(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_owned") and @TypeOf(@field(T, "is_napi_owned")) == bool and @field(T, "is_napi_owned");
}

/// Payload type of a `napi.Owned` wrapper.
pub fn ownedPayload(comptime T: type) type {
    if (!isOwned(T)) {
        @compileError("Type is not napi.Owned: " ++ @typeName(T));
    }
    return @field(T, "owned_payload_type");
}

/// True for the error payload types of this library. Their message strings are
/// borrowed, so ownership handling must skip them entirely.
pub fn isErrorValue(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_error") and @TypeOf(@field(T, "is_napi_error")) == bool and @field(T, "is_napi_error");
}

/// True when the type is backed by a JavaScript handle instead of native memory.
/// Such values must not be declared thread safe, cloned or freed by native code.
pub fn isJsHandle(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (isOwned(T)) return false;
    if (T == @import("napi-sys").napi_sys.napi_value) return true;
    // Every JS backed wrapper in this library exposes `from_raw` and stores an
    // `env`/`raw` pair. User data types must not declare `from_raw`.
    return @hasDecl(T, "from_raw") or
        isNapiFunction(T) or
        isThreadSafeFunction(T) or
        isTypedArray(T) or
        isDataView(T) or
        isReference(T) or
        isExternal(T) or
        isAbortSignal(T) or
        isErrorValue(T);
}

pub fn isDts(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_dts") and @TypeOf(@field(T, "is_napi_dts")) == bool and @field(T, "is_napi_dts");
}

pub fn isArrayList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        return false;
    }
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) {
            return true;
        }
    }
    return false;
}

pub fn getArrayListElementType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Expected struct type for ArrayList");
    }

    for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) {
            const items_type_info = @typeInfo(field.type);
            if (items_type_info == .pointer and items_type_info.pointer.size == .slice) {
                return items_type_info.pointer.child;
            }
        }
    }

    @compileError("Could not extract element type from ArrayList: " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// Conversion rollback
// ---------------------------------------------------------------------------

/// A resource that a conversion created and that must be released again when
/// the conversion does not complete.
///
/// Only *created* JavaScript resources are tracked here. Borrowed handles
/// (`NapiValue`, `Function`, wrapped objects) stay with the runtime and must
/// never be released by the conversion layer.
pub const TrackedResource = union(enum) {
    /// Strong reference created with `napi_create_reference` while converting
    /// an argument (`napi.Reference(T)`, `napi.ObjectRef`, `FunctionRef`).
    /// Deleting it drops exactly the count the conversion added, which is what
    /// makes the JavaScript value collectible again.
    ///
    /// The deleter comes from the reference wrapper instead of being called
    /// from here: a build that never converts a reference must not have to link
    /// the N-API symbol for it.
    reference: struct {
        env: napi.napi_env,
        handle: napi.napi_ref,
        release: *const fn (napi.napi_env, napi.napi_ref) void,
    },
    /// Resource owned by another subsystem (for example a TSFN wrapper).
    /// `undo` receives `context` unchanged and must release the resource
    /// exactly once; it runs while the creating frame is still alive.
    custom: struct {
        context: ?*anyopaque,
        undo: *const fn (?*anyopaque) void,
    },
};

fn undoResource(resource: TrackedResource) void {
    switch (resource) {
        .reference => |entry| {
            // The only handle that may still exist at this point is the one this
            // conversion created: it was never handed to user code.
            entry.release(entry.env, entry.handle);
        },
        .custom => |entry| entry.undo(entry.context),
    }
}

/// One argument-conversion transaction.
///
/// Resources created while converting arguments belong to the conversion until
/// it completes. When a later argument fails (or the conversion is abandoned)
/// `rollbackUncommitted` releases every resource the conversion created, so a
/// failed call cannot retain JavaScript objects or keep the process alive. Once
/// the native body is about to run the frame is *committed*: from that point on
/// the converted arguments (including a promoted `ThreadSafeFunction`) belong to
/// the body and are never rolled back.
///
/// Frames nest per thread with stack discipline: a reentrant JavaScript callback
/// that enters another exported function installs its own frame and sees the
/// outer frame again when it returns. A frame must keep the same address from
/// `start` until `end` ran; it must not be copied while installed.
pub const ConversionFrame = struct {
    allocator: std.mem.Allocator = undefined,
    outer: ?*ConversionFrame = null,
    pending: std.ArrayListUnmanaged(TrackedResource) = .empty,
    committed: bool = false,

    const Self = @This();

    /// Install this frame as the active conversion of the current thread.
    /// `allocator` releases the bookkeeping list and must stay valid until
    /// `end` ran.
    pub fn start(self: *Self, allocator: std.mem.Allocator) void {
        // Installing the same frame twice would make it its own outer frame.
        std.debug.assert(current_frame != self);
        self.allocator = allocator;
        self.outer = current_frame;
        self.pending = .empty;
        self.committed = false;
        current_frame = self;
    }

    /// Hand every tracked resource over to the caller of the conversion.
    /// Resources created after this point are not tracked any more: they belong
    /// to whatever the native body does with them.
    pub fn commit(self: *Self) void {
        self.committed = true;
        self.pending.clearRetainingCapacity();
    }

    /// Release every resource that was created but never handed over. Idempotent.
    pub fn rollbackUncommitted(self: *Self) void {
        if (self.committed) return;
        var index = self.pending.items.len;
        while (index > 0) {
            index -= 1;
            undoResource(self.pending.items[index]);
        }
        self.pending.clearRetainingCapacity();
    }

    /// Roll back (if needed), restore the previous frame and release the
    /// bookkeeping list. Must be the last call on a started frame.
    pub fn end(self: *Self) void {
        // Frames unwind in reverse order of `start`.
        std.debug.assert(current_frame == self);
        self.rollbackUncommitted();
        current_frame = self.outer;
        self.pending.deinit(self.allocator);
        self.pending = .empty;
        self.allocator = undefined;
        self.committed = false;
        self.outer = null;
    }
};

/// Active conversion of the current thread, if any.
threadlocal var current_frame: ?*ConversionFrame = null;

/// The conversion that is currently converting arguments, if any.
pub fn activeConversionFrame() ?*ConversionFrame {
    return current_frame;
}

/// The active conversion frame that still owns the resources it creates, if any.
///
/// A *committed* frame belongs to the native body that is running: a conversion
/// started after the commit (a manual `Napi.from_napi_value*` inside the body)
/// must not attribute its resources to that frame, because the frame will never
/// roll back again. Callers that convert values start their own frame in that
/// case.
pub fn activeUncommittedConversionFrame() ?*ConversionFrame {
    const frame = current_frame orelse return null;
    return if (frame.committed) null else frame;
}

/// Record a resource the caller just created.
///
/// With no active frame (a `Reference`/TSFN created by user code, outside any
/// argument conversion) this is a no-op and ownership stays with the caller.
/// With a committed frame the resource was created by a native body that already
/// owns it, so it is not tracked either. `error.OutOfMemory` means the caller
/// must release the resource it just created and fail the conversion: without a
/// bookkeeping slot the framework cannot promise the rollback.
pub fn trackResource(resource: TrackedResource) !void {
    const frame = current_frame orelse return;
    if (frame.committed) return;
    try frame.pending.append(frame.allocator, resource);
}

/// Track a strong reference created during an argument conversion.
/// `release` deletes the reference handle.
pub fn trackReference(env: napi.napi_env, handle: napi.napi_ref, release: *const fn (napi.napi_env, napi.napi_ref) void) !void {
    return trackResource(.{ .reference = .{ .env = env, .handle = handle, .release = release } });
}

/// Track a resource owned by another subsystem. `undo` runs exactly once, while
/// the creating conversion is still failing.
pub fn trackCustom(context: ?*anyopaque, undo: *const fn (?*anyopaque) void) !void {
    return trackResource(.{ .custom = .{ .context = context, .undo = undo } });
}

pub fn comptimeFloatMode(comptime value: comptime_float) type {
    const f32_min = math.floatMin(f32);
    const f32_max = math.floatMax(f32);
    const f64_min = math.floatMin(f64);
    const f64_max = math.floatMax(f64);

    // Check if it can be converted to f32 without loss
    if (value >= f32_min and value <= f32_max) {
        const as_f32: f32 = value;
        const back_to_comptime: f64 = as_f32; // 通过 f64 来比较
        if (@abs(back_to_comptime - @as(f64, value)) < 1e-6) {
            return f32;
        }
    }

    // Check if it can be converted to f64 without loss
    if (value >= f64_min and value <= f64_max) {
        const as_f64: f64 = value;
        const back_to_comptime: f128 = as_f64;
        if (@abs(back_to_comptime - @as(f128, value)) < 1e-15) {
            return f64;
        }
    }

    // Otherwise, it needs f128
    return f128;
}

pub fn comptimeIntMode(comptime value: comptime_int) type {
    // Check if it can be converted to i32 without loss
    if (value >= math.minInt(i32) and value <= math.maxInt(i32)) {
        return i32;
    }

    // Check if it can be converted to i64 without loss
    if (value >= math.minInt(i64) and value <= math.maxInt(i64)) {
        return i64;
    }

    return i128;
}

pub fn collectFunctionArgs(comptime functions: anytype) type {
    const infos = @typeInfo(functions);
    if (infos != .@"fn") {
        @compileError("Expected function type for collectFunctionArgs");
    }

    if (infos.@"fn".params.len == 0) {
        return void;
    }

    if (infos.@"fn".params.len == 1) {
        return infos.@"fn".params[0].type.?;
    }

    const args_len = infos.@"fn".params.len;

    var field_types: [args_len]type = undefined;

    inline for (0..args_len) |i| {
        field_types[i] = infos.@"fn".params[i].type.?;
    }

    return std.meta.Tuple(&field_types);
}

pub fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // Drop generic arguments before splitting so `a.b.External(a.c.Object, i32)`
    // is reported as `External`.
    const head = if (std.mem.indexOfScalar(u8, full, '(')) |open| full[0..open] else full;
    var iter = std.mem.splitBackwardsScalar(u8, head, '.');
    return iter.first();
}

// ---------------------------------------------------- conversion rollback tests

const RollbackRecorder = struct {
    released: usize = 0,

    fn undo(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        self.released += 1;
    }
};

test "a failing conversion rolls back every resource it created" {
    var recorder = RollbackRecorder{};
    var frame = ConversionFrame{};
    frame.start(std.testing.allocator);
    defer frame.end();

    try trackCustom(&recorder, RollbackRecorder.undo);
    try trackCustom(&recorder, RollbackRecorder.undo);
    frame.rollbackUncommitted();

    try std.testing.expectEqual(@as(usize, 2), recorder.released);
    // The rollback is idempotent: the normal teardown must not release twice.
    frame.rollbackUncommitted();
    try std.testing.expectEqual(@as(usize, 2), recorder.released);
}

test "a committed conversion keeps its resources" {
    var recorder = RollbackRecorder{};
    {
        var frame = ConversionFrame{};
        frame.start(std.testing.allocator);
        defer frame.end();

        try trackCustom(&recorder, RollbackRecorder.undo);
        frame.commit();
        frame.rollbackUncommitted();
        try std.testing.expectEqual(@as(usize, 0), recorder.released);

        // A resource created by the committed body belongs to the body.
        try trackCustom(&recorder, RollbackRecorder.undo);
    }
    // Neither the rollback nor the teardown may release what was committed.
    try std.testing.expectEqual(@as(usize, 0), recorder.released);
}

test "nested conversion frames only release their own resources" {
    var outer = RollbackRecorder{};
    var inner = RollbackRecorder{};

    var outer_frame = ConversionFrame{};
    outer_frame.start(std.testing.allocator);
    defer outer_frame.end();
    try std.testing.expect(activeConversionFrame() == &outer_frame);
    try trackCustom(&outer, RollbackRecorder.undo);

    {
        var inner_frame = ConversionFrame{};
        inner_frame.start(std.testing.allocator);
        defer inner_frame.end();
        try std.testing.expect(activeConversionFrame() == &inner_frame);
        try trackCustom(&inner, RollbackRecorder.undo);
        inner_frame.rollbackUncommitted();
        try std.testing.expectEqual(@as(usize, 1), inner.released);
        try std.testing.expectEqual(@as(usize, 0), outer.released);
    }

    // A reentrant callback returns the outer conversion to the thread.
    try std.testing.expect(activeConversionFrame() == &outer_frame);
    outer_frame.rollbackUncommitted();
    try std.testing.expectEqual(@as(usize, 1), outer.released);
}

test "resources created outside a conversion stay with their owner" {
    var recorder = RollbackRecorder{};
    try std.testing.expect(activeConversionFrame() == null);
    try std.testing.expect(activeUncommittedConversionFrame() == null);
    try trackCustom(&recorder, RollbackRecorder.undo);
    try std.testing.expectEqual(@as(usize, 0), recorder.released);
}

test "a committed frame does not adopt conversions started after it" {
    var frame = ConversionFrame{};
    frame.start(std.testing.allocator);
    defer frame.end();

    try std.testing.expect(activeUncommittedConversionFrame() == &frame);
    frame.commit();
    // The frame belongs to the running body now: a conversion started here must
    // install its own frame instead of handing its resources to one that will
    // never roll back.
    try std.testing.expect(activeConversionFrame() == &frame);
    try std.testing.expect(activeUncommittedConversionFrame() == null);
}

test "a resource that could not be registered stays with its creator" {
    // The first allocation of the bookkeeping list fails: the caller is told,
    // keeps ownership of the resource it just created, and the frame stays
    // usable for the registrations that follow.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var recorder = RollbackRecorder{};
    var frame = ConversionFrame{};
    frame.start(failing.allocator());
    defer frame.end();

    try std.testing.expectError(error.OutOfMemory, trackCustom(&recorder, RollbackRecorder.undo));

    // A failed registration leaves the frame consistent: the allocator recovers
    // and the next resource is recorded and rolled back normally.
    failing.fail_index = std.math.maxInt(usize);
    try trackCustom(&recorder, RollbackRecorder.undo);
    frame.rollbackUncommitted();
    try std.testing.expectEqual(@as(usize, 1), recorder.released);
}
