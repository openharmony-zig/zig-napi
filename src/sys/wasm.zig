//! WASI (wasm32-wasip1) support for the Node-API surface.
//!
//! A WASI addon links emnapi's `libemnapi-basic-napi-rs.a`, which binds every
//! `napi_*` reference to the `env` wasm import module and leaves async work and
//! thread-safe functions to the `@emnapi/core` plugins. The functions in this
//! file are the few entry points `src/sys/node.zig` routes through Zig instead
//! of calling them directly; each one forwards to the very implementation the
//! archive ships, so the ABI stays emnapi's rather than a hand-written copy.
//! (`napi_get_last_error_info`, `napi_async_init`, `napi_async_destroy`,
//! `napi_add/remove_async_cleanup_hook`, `napi_get_node_version` and
//! `node_api_get_module_file_name` are all defined by the archive; `@emnapi/core`
//! v2 moved the last-error state into the C env struct, so there is no
//! `_emnapi_get_last_error_info` import to call any more.)
//!
//! Threaded (shared memory) addons additionally export the async work pool
//! entry points `@emnapi/core` calls: `emnapi_async_worker_create` below and
//! `emnapi_async_worker_init`. emnapi v2 publishes their C implementations in
//! no WASI archive, and they must write the `__stack_pointer` / `__tls_base`
//! wasm globals, so both live here.

const builtin = @import("builtin");
const std = @import("std");

const node = @import("types.zig");

const is_enabled = builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;

/// A threaded (shared memory) WASI addon is built with
/// `-Dcpu=baseline+atomics+bulk_memory+mutable_globals`, which is also what
/// makes `@emnapi/core` drive its async work through a worker pool. Only those
/// builds export the pool entry points: a single-threaded addon has no workers
/// to enter, and the exports would drag in the `_emnapi_spawn_worker` and
/// `_emnapi_async_worker` host imports for nothing.
const is_threaded = is_enabled and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);

pub const enabled = enabled: {
    _ = AsyncWorkerExports;
    break :enabled is_enabled;
};

pub fn setup() void {
    _ = AsyncWorkerExports;
}

/// `@extern` with a name that the linked emnapi archive also defines: the
/// linker binds the reference to that definition, and the symbol only stays an
/// import when nothing defines it.
pub fn callEmnapiApi(comptime name: [:0]const u8, comptime Fn: type, args: anytype) apiReturnType(Fn) {
    const function = @extern(Fn, .{ .name = name });
    return @call(.auto, function, args);
}

fn apiReturnType(comptime Fn: type) type {
    return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
}

pub fn getLastErrorInfo(env: node.node_api_basic_env, result: [*c][*c]const node.napi_extended_error_info) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env, [*c][*c]const node.napi_extended_error_info) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_get_last_error_info", Fn, .{ env, result });
}

pub fn getNodeVersion(env: node.node_api_basic_env, version: [*c][*c]const node.napi_node_version) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env, [*c][*c]const node.napi_node_version) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_get_node_version", Fn, .{ env, version });
}

pub fn getModuleFileName(env: node.node_api_basic_env, result: [*c][*c]const u8) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env, [*c][*c]const u8) callconv(.c) node.napi_status;
    return callEmnapiApi("node_api_get_module_file_name", Fn, .{ env, result });
}

pub fn asyncInit(env: node.napi_env, async_resource: node.napi_value, async_resource_name: node.napi_value, result: [*c]node.napi_async_context) node.napi_status {
    const Fn = *const fn (node.napi_env, node.napi_value, node.napi_value, [*c]node.napi_async_context) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_async_init", Fn, .{ env, async_resource, async_resource_name, result });
}

pub fn asyncDestroy(env: node.napi_env, async_context: node.napi_async_context) node.napi_status {
    const Fn = *const fn (node.napi_env, node.napi_async_context) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_async_destroy", Fn, .{ env, async_context });
}

pub fn addAsyncCleanupHook(env: node.node_api_basic_env, hook: node.napi_async_cleanup_hook, data: ?*anyopaque, remove_handle: [*c]node.napi_async_cleanup_hook_handle) node.napi_status {
    const Fn = *const fn (node.node_api_basic_env, node.napi_async_cleanup_hook, ?*anyopaque, [*c]node.napi_async_cleanup_hook_handle) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_add_async_cleanup_hook", Fn, .{ env, hook, data, remove_handle });
}

pub fn removeAsyncCleanupHook(remove_handle: node.napi_async_cleanup_hook_handle) node.napi_status {
    const Fn = *const fn (node.napi_async_cleanup_hook_handle) callconv(.c) node.napi_status;
    return callEmnapiApi("napi_remove_async_cleanup_hook", Fn, .{remove_handle});
}

pub fn syncMemory(env: node.napi_env, js_to_wasm: bool, array: [*c]node.napi_value, byte_offset: usize, byte_length: usize) node.napi_status {
    if (enabled) {
        const Fn = *const fn (node.napi_env, bool, [*c]node.napi_value, usize, usize) callconv(.c) node.napi_status;
        return callEmnapiApi("emnapi_sync_memory", Fn, .{ env, js_to_wasm, array, byte_offset, byte_length });
    }
    return node.napi_ok;
}

// ---------------------------------------------------------------------------
// Async work pool (threaded flavor)
// ---------------------------------------------------------------------------

/// `struct worker_args` from emnapi's `src/thread/async_worker_create.c`: the
/// host reads `stack_base` at offset 0 and `tls_base` at offset
/// `@sizeOf(usize)` when a worker starts, so this layout is ABI.
const AsyncWorkerArgs = extern struct {
    stack_base: ?*anyopaque,
    tls_base: ?*anyopaque,
};

/// Stack handed to each pooled worker. emnapi's C allocator derives this from
/// the linker's `__stack_high`/`__stack_low` and clamps it to 8 MiB; those are
/// weak link-time symbols, which Zig cannot declare, so this hands out a fixed
/// size that comfortably covers a user's `execute` callback.
const async_worker_stack_size = 2 * 1024 * 1024;

/// The wasm ABI keeps the stack pointer 16 byte aligned.
const async_worker_stack_align = 16;

extern fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque;

extern fn _emnapi_async_worker(arg: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn _emnapi_spawn_worker(worker: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) callconv(.c) c_int;

/// Synthetic function emitted by wasm-ld: copies the TLS image into `memory`
/// and installs it as the current thread's TLS base.
extern fn __wasm_init_tls(memory: [*]u8) callconv(.c) void;

/// Linker-provided TLS layout, read through the wasm globals lld emits. Zig's
/// `std.Thread.Wasm` reads them the same way; there is no builtin for it.
inline fn wasmTlsSize() u32 {
    return asm volatile (
        \\.globaltype __tls_size, i32, immutable
        \\global.get __tls_size
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
    );
}

inline fn wasmTlsAlign() u32 {
    return asm (
        \\.globaltype __tls_align, i32, immutable
        \\global.get __tls_align
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
    );
}

inline fn wasmTlsBase() usize {
    return asm (
        \\.globaltype __tls_base, i32
        \\global.get __tls_base
        \\local.set %[ret]
        : [ret] "=r" (-> usize),
    );
}

inline fn setWasmTlsBase(addr: usize) void {
    asm volatile (
        \\local.get %[ptr]
        \\global.set __tls_base
        :
        : [ptr] "r" (addr),
    );
}

/// Prepares the TLS block for a worker and returns its base, leaving the
/// caller's own TLS installed. Mirrors `__copy_tls` in
/// `async_worker_create.c`, which wasi-libc exposes to C but not to Zig.
fn copyTls(memory: [*]u8) [*]u8 {
    const previous_base = wasmTlsBase();
    __wasm_init_tls(memory);
    setWasmTlsBase(previous_base);
    return memory;
}

/// `emnapi_async_worker_create`: `directly_spawn != 0` asks the host to spawn a
/// pooled worker, anything else allocates the block the worker's entry point
/// installs. Returns 0 when no worker could be created.
pub fn workerCreate(directly_spawn: c_int, global_address: ?*anyopaque) c_int {
    // Mirrors `emnapi_async_worker_create` from emnapi's
    // `src/thread/async_worker_create.c`. The host calls this with
    // `directly_spawn != 0` while filling the pool (it must end up in the
    // host's own spawn path) and with `directly_spawn == 0` to obtain the
    // per-worker block that `emnapi_async_worker_init` later installs.
    if (directly_spawn != 0) {
        const index = _emnapi_spawn_worker(_emnapi_async_worker, global_address);
        // The host reports the pool slot as `-(index + 1)`; zero means "no
        // worker". Same expression as the C `(void*)(intptr_t)(-(index + 1))`.
        return -index - 1;
    }

    const args_size = @sizeOf(AsyncWorkerArgs);
    const stack_size = std.mem.alignForward(usize, async_worker_stack_size, async_worker_stack_align);
    const tls_size = wasmTlsSize();
    const tls_align = if (tls_size == 0) @as(usize, 1) else wasmTlsAlign();
    // Room for the aligned TLS image plus the alignment slack it may need.
    const tls_block_size = if (tls_size == 0) 0 else std.mem.alignForward(usize, tls_size, tls_align) + tls_align;
    const block_size = args_size + tls_block_size + stack_size + async_worker_stack_align;

    const block_ptr = calloc(1, block_size) orelse return 0;
    const block_addr = @intFromPtr(block_ptr);

    var tls_base: ?*anyopaque = null;
    if (tls_size != 0) {
        const tls_addr = std.mem.alignForward(usize, block_addr + args_size, tls_align);
        tls_base = @ptrCast(copyTls(@ptrFromInt(tls_addr)));
    }

    // The stack grows downwards from an aligned top, after the TLS block.
    const stack_top = std.mem.alignForward(
        usize,
        block_addr + args_size + tls_block_size + stack_size,
        async_worker_stack_align,
    );
    const args: *AsyncWorkerArgs = @ptrCast(@alignCast(block_ptr));
    args.* = .{
        .stack_base = @ptrFromInt(stack_top),
        .tls_base = tls_base,
    };
    // The host stores this value as a 32 bit wasm pointer and hands it back to
    // `emnapi_async_worker_init`. `@bitCast` keeps the highest bit intact:
    // `@intCast` would trap for any block above 2 GiB even though wasm32 memory
    // may be 4 GiB.
    return @bitCast(@as(u32, @truncate(block_addr)));
}

/// `emnapi_async_worker_init` is `src/sys/emnapi_async_worker_init.S`: it has
/// to switch `__stack_pointer` and `__tls_base` and then return with those
/// values still installed, which no function with a prologue can do (the
/// epilogue restores the incoming stack pointer).
const AsyncWorkerExports = if (is_threaded) struct {
    export fn emnapi_async_worker_create(directly_spawn: c_int, global_address: ?*anyopaque) callconv(.c) c_int {
        return workerCreate(directly_spawn, global_address);
    }
} else struct {};
