const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const arraybuffer_mod = @import("./arraybuffer.zig");
const ArrayBuffer = arraybuffer_mod.ArrayBuffer;
const NapiError = @import("./error.zig");
const options = @import("../options.zig");
const Endian = std.builtin.Endian;

pub const DataView = struct {
    pub const is_napi_dataview = true;

    env: napi.napi_env,
    raw: napi.napi_value,
    data: [*]u8,
    byte_length: usize,
    byte_offset: usize,
    arraybuffer: ArrayBuffer,

    /// Whether this wrapper refers to a usable DataView.
    pub fn isValid(self: DataView) bool {
        return self.raw != null;
    }

    /// Create a wrapper from a raw napi_value.
    ///
    /// Kept for source compatibility with the previous infallible API: the
    /// N-API status is checked, and a value that is not a DataView throws a
    /// JavaScript `TypeError` and yields an invalid wrapper. Prefer
    /// `tryFromRaw` when the failure has to be handled in Zig.
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) DataView {
        return DataView.tryFromRaw(env, raw) catch |err| {
            arraybuffer_mod.recordBinaryFailure("DataView expected", err);
            return invalid(env, null);
        };
    }

    /// Create a wrapper from a raw napi_value, validating the N-API status and
    /// the backing store.
    pub fn tryFromRaw(env: napi.napi_env, raw: napi.napi_value) !DataView {
        var byte_length: usize = 0;
        var data: ?*anyopaque = null;
        var arraybuffer_raw: napi.napi_value = undefined;
        var byte_offset: usize = 0;

        const status = napi.napi_get_dataview_info(
            env,
            raw,
            &byte_length,
            &data,
            &arraybuffer_raw,
            &byte_offset,
        );
        if (status != napi.napi_ok) {
            if (NapiError.Status.New(status) == .InvalidArg) {
                return arraybuffer_mod.BinaryError.InvalidBinaryValue;
            }
            return NapiError.toError(NapiError.Status.New(status));
        }

        const backing = ArrayBuffer.tryFromRaw(env, arraybuffer_raw) catch {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        };
        if (try arraybuffer_mod.backingIsDetached(env, arraybuffer_raw)) {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        }
        if (byte_offset > backing.length() or byte_length > backing.length() - byte_offset) {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        }
        if (byte_length > 0 and data == null) {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        }

        return DataView{
            .env = env,
            .raw = raw,
            .data = if (byte_length == 0 or data == null) &[_]u8{} else @ptrCast(data),
            .byte_length = byte_length,
            .byte_offset = byte_offset,
            .arraybuffer = backing,
        };
    }

    pub fn invalid(env: napi.napi_env, raw: napi.napi_value) DataView {
        return DataView{
            .env = env,
            .raw = raw,
            .data = &[_]u8{},
            .byte_length = 0,
            .byte_offset = 0,
            .arraybuffer = ArrayBuffer.invalid(env, null),
        };
    }

    pub fn fromArrayBuffer(env: Env, arraybuffer: ArrayBuffer, byte_offset: usize, byte_length: usize) !DataView {
        const end = std.math.add(usize, byte_offset, byte_length) catch {
            return NapiError.Error.rangeError("DataView offset overflows the byte range");
        };
        if (end > arraybuffer.length()) {
            return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
        }

        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_dataview(
            env.raw,
            byte_length,
            arraybuffer.raw,
            byte_offset,
            &raw,
        );

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return DataView.tryFromRaw(env.raw, raw);
    }

    pub fn New(env: Env, byte_length: usize) !DataView {
        const arraybuffer = try ArrayBuffer.New(env, byte_length);
        return DataView.fromArrayBuffer(env, arraybuffer, 0, byte_length);
    }

    pub fn copy(env: Env, data: []const u8) !DataView {
        const arraybuffer = try ArrayBuffer.copy(env, data);
        const result = try DataView.fromArrayBuffer(env, arraybuffer, 0, data.len);
        try result.flush();
        return result;
    }

    pub fn from(env: Env, data: []u8) !DataView {
        const arraybuffer = try ArrayBuffer.from(env, data);
        const result = try DataView.fromArrayBuffer(env, arraybuffer, 0, data.len);
        try result.flush();
        return result;
    }

    /// Re-query the view and refresh the cached pointer, length and offset.
    pub fn refresh(self: *DataView) !void {
        const refreshed = try DataView.tryFromRaw(self.env, self.raw);
        self.data = refreshed.data;
        self.byte_length = refreshed.byte_length;
        self.byte_offset = refreshed.byte_offset;
        self.arraybuffer = refreshed.arraybuffer;
    }

    /// Borrowed native view of the DataView contents, re-validated against the
    /// backing store on every call.
    ///
    /// Fails when the wrapper is invalid or when the backing store was
    /// detached, transferred or resized since the wrapper was created. The
    /// returned slice stays valid only until the next JavaScript reentry.
    pub fn tryAsSlice(self: DataView) ![]u8 {
        if (self.raw == null) return arraybuffer_mod.BinaryError.InvalidBinaryValue;
        // emnapi reads DataView.byteLength inside get_dataview_info; that
        // accessor itself throws after detach. Check the retained backing first.
        if (try arraybuffer_mod.backingIsDetached(self.env, self.arraybuffer.raw)) {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        }
        const refreshed = try DataView.tryFromRaw(self.env, self.raw);
        if (refreshed.byte_length != self.byte_length) return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        return refreshed.data[0..refreshed.byte_length];
    }

    /// Safe variant of `asConstSlice`.
    pub fn tryAsConstSlice(self: DataView) ![]const u8 {
        return try self.tryAsSlice();
    }

    /// Borrowed native view of the DataView contents.
    ///
    /// The view is re-validated on every call; when the backing store is no
    /// longer valid the result is an empty slice rather than a dangling
    /// pointer. Use `tryAsSlice` to observe the failure.
    pub fn asSlice(self: DataView) []u8 {
        return self.tryAsSlice() catch &[_]u8{};
    }

    /// Const variant of `asSlice`. See `asSlice` for the empty-slice rule.
    pub fn asConstSlice(self: DataView) []const u8 {
        return self.tryAsSlice() catch &[_]u8{};
    }

    pub fn byteLength(self: DataView) usize {
        return self.byte_length;
    }

    /// Sync wasm-side mutations back to the JavaScript DataView when running on emnapi.
    pub fn flush(self: DataView) !void {
        try self.flushRange(0, self.byte_length);
    }

    /// Sync wasm-side mutations for a byte range relative to this DataView.
    pub fn flushRange(self: DataView, byte_offset: usize, byte_length: usize) !void {
        if (comptime !options.isWasmNodeAddon()) return;
        // get_dataview_info synchronizes JS -> Wasm in emnapi and would erase
        // the writes that this method is meant to publish. The write accessor
        // already revalidated the view; check detachment without pulling data.
        if (try arraybuffer_mod.backingIsDetached(self.env, self.arraybuffer.raw)) {
            return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
        }
        try self.ensureRange(byte_offset, byte_length);
        if (byte_length == 0) return;
        var raw = self.raw;
        const status = napi.emnapi_sync_memory(self.env, false, &raw, byte_offset, byte_length);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
    }

    fn endianOf(little_endian: bool) Endian {
        return if (little_endian) .little else .big;
    }

    fn ensureRange(self: DataView, byte_offset: usize, len: usize) !void {
        if (byte_offset > self.byte_length or len > self.byte_length - byte_offset) {
            return NapiError.Error.rangeError("DataView offset is out of bounds");
        }
    }

    /// Resolves the bytes for one access. The view is re-validated first, so a
    /// detached backing store can never be read through a cached pointer.
    fn bytesAt(self: DataView, byte_offset: usize, len: usize) ![]u8 {
        try self.ensureRange(byte_offset, len);
        const slice = try self.tryAsSlice();
        return slice[byte_offset .. byte_offset + len];
    }

    pub fn readInt(self: DataView, comptime T: type, byte_offset: usize, little_endian: bool) !T {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError("readInt only supports integer types");
        }

        const bytes = try self.bytesAt(byte_offset, @sizeOf(T));
        const fixed: *const [@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(T, fixed, endianOf(little_endian));
    }

    pub fn writeInt(self: DataView, comptime T: type, byte_offset: usize, value: T, little_endian: bool) !void {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError("writeInt only supports integer types");
        }

        const bytes = try self.bytesAt(byte_offset, @sizeOf(T));
        const fixed: *[@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        std.mem.writeInt(T, fixed, value, endianOf(little_endian));
    }

    pub fn readFloat(self: DataView, comptime T: type, byte_offset: usize, little_endian: bool) !T {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("readFloat only supports floating-point types");
        }

        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        const bits = try self.readInt(Bits, byte_offset, little_endian);
        return @bitCast(bits);
    }

    pub fn writeFloat(self: DataView, comptime T: type, byte_offset: usize, value: T, little_endian: bool) !void {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("writeFloat only supports floating-point types");
        }

        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        try self.writeInt(Bits, byte_offset, @bitCast(value), little_endian);
    }

    pub fn getInt8(self: DataView, byte_offset: usize) !i8 {
        return self.readInt(i8, byte_offset, true);
    }

    pub fn getUint8(self: DataView, byte_offset: usize) !u8 {
        return self.readInt(u8, byte_offset, true);
    }

    pub fn getInt16(self: DataView, byte_offset: usize, little_endian: bool) !i16 {
        return self.readInt(i16, byte_offset, little_endian);
    }

    pub fn getUint16(self: DataView, byte_offset: usize, little_endian: bool) !u16 {
        return self.readInt(u16, byte_offset, little_endian);
    }

    pub fn getInt32(self: DataView, byte_offset: usize, little_endian: bool) !i32 {
        return self.readInt(i32, byte_offset, little_endian);
    }

    pub fn getUint32(self: DataView, byte_offset: usize, little_endian: bool) !u32 {
        return self.readInt(u32, byte_offset, little_endian);
    }

    pub fn getBigInt64(self: DataView, byte_offset: usize, little_endian: bool) !i64 {
        return self.readInt(i64, byte_offset, little_endian);
    }

    pub fn getBigUint64(self: DataView, byte_offset: usize, little_endian: bool) !u64 {
        return self.readInt(u64, byte_offset, little_endian);
    }

    pub fn getFloat32(self: DataView, byte_offset: usize, little_endian: bool) !f32 {
        return self.readFloat(f32, byte_offset, little_endian);
    }

    pub fn getFloat64(self: DataView, byte_offset: usize, little_endian: bool) !f64 {
        return self.readFloat(f64, byte_offset, little_endian);
    }

    pub fn setInt8(self: DataView, byte_offset: usize, value: i8) !void {
        try self.writeInt(i8, byte_offset, value, true);
    }

    pub fn setUint8(self: DataView, byte_offset: usize, value: u8) !void {
        try self.writeInt(u8, byte_offset, value, true);
    }

    pub fn setInt16(self: DataView, byte_offset: usize, value: i16, little_endian: bool) !void {
        try self.writeInt(i16, byte_offset, value, little_endian);
    }

    pub fn setUint16(self: DataView, byte_offset: usize, value: u16, little_endian: bool) !void {
        try self.writeInt(u16, byte_offset, value, little_endian);
    }

    pub fn setInt32(self: DataView, byte_offset: usize, value: i32, little_endian: bool) !void {
        try self.writeInt(i32, byte_offset, value, little_endian);
    }

    pub fn setUint32(self: DataView, byte_offset: usize, value: u32, little_endian: bool) !void {
        try self.writeInt(u32, byte_offset, value, little_endian);
    }

    pub fn setBigInt64(self: DataView, byte_offset: usize, value: i64, little_endian: bool) !void {
        try self.writeInt(i64, byte_offset, value, little_endian);
    }

    pub fn setBigUint64(self: DataView, byte_offset: usize, value: u64, little_endian: bool) !void {
        try self.writeInt(u64, byte_offset, value, little_endian);
    }

    pub fn setFloat32(self: DataView, byte_offset: usize, value: f32, little_endian: bool) !void {
        try self.writeFloat(f32, byte_offset, value, little_endian);
    }

    pub fn setFloat64(self: DataView, byte_offset: usize, value: f64, little_endian: bool) !void {
        try self.writeFloat(f64, byte_offset, value, little_endian);
    }
};
