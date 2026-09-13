//! Thread-safe C allocator entry points for threaded WASI addons.
//!
//! A threaded (`wasm32-wasip1-threads`) addon hands one shared linear memory to
//! several JavaScript worker instances. The `@emnapi/core` plugins allocate work
//! records, event payloads and thread-safe-function queue nodes with the
//! module's exported `malloc`/`free` *from every one of those workers*, and the
//! allocator behind those symbols — Zig's `lib/c/malloc.zig` over
//! `std.heap.WasmAllocator` (`BrkAllocator`) — keeps its free lists in a plain
//! module-level global with no synchronization, because Zig only builds
//! single-threaded wasm. Concurrent producers therefore interleave inside one
//! allocator: two workers pop the same free-list node, or one worker overwrites
//! another's block header. The first symptom is a trap in
//! `c.malloc.Header.get` ("reached unreachable code") raised from the plugin's
//! queue code, and the same corruption can silently hand out overlapping blocks.
//!
//! This compilation unit provides strong `malloc` / `free` / `calloc` /
//! `realloc` / … definitions that take one shared spin lock around a single
//! `std.heap.WasmAllocator` instance. Zig's libc exports its allocator symbols
//! as *weak* (`lib/c.zig`, `symbol()`) exactly so they can be overridden by a
//! regular object, which is what this file is: it is compiled into its own
//! object without linking libc (a strong definition in the same Zig
//! compilation unit as libc is a compile-time "exported symbol collision"), and
//! the linker resolves every allocator reference to these.
//!
//! Locking rules:
//!
//! * One lock, taken exactly once per entry point. The `*Impl` functions below
//!   never call a public entry point, so `calloc` -> `malloc` and
//!   `realloc` -> `malloc`/`free` cannot deadlock on a non-recursive lock.
//! * The critical section only touches the allocator (`BrkAllocator` grows the
//!   linear memory with `@wasmMemoryGrow`, which is atomic in wasm); it never
//!   calls back into JavaScript or waits on another thread.
//! * The lock never uses `memory.atomic.wait`: a blocking wait is not allowed on
//!   the JavaScript main thread, which also calls these functions. It spins
//!   instead, and every critical section is a handful of instructions.
//!
//! It is linked only for the threaded flavor: a single-threaded addon has one
//! thread, so the plain libc allocator is already correct there and stays in use.

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

/// Which allocator backs these entry points: the same `BrkAllocator` Zig's libc
/// uses for wasm (`std.heap.WasmAllocator`), so heap growth and the address
/// range are unchanged. It is the only instance in the link because every
/// libc allocator symbol resolves here.
const vtable = std.heap.WasmAllocator.vtable;

const no_context: *anyopaque = undefined;
const no_ra: usize = undefined;

/// Mirrors `Header` in Zig's `lib/c/malloc.zig`: the size and alignment libc
/// callers cannot pass along are stored just before the user pointer, inside the
/// alignment padding.
const alignment_bytes = @max(@alignOf(std.c.max_align_t), @sizeOf(Header));
const alignment: Alignment = .fromByteUnits(alignment_bytes);

const Header = packed struct(u64) {
    alignment: Alignment,
    /// Does not include the extra alignment bytes added.
    size: Size,
    canary: Canary = magic,

    comptime {
        assert(@sizeOf(Header) <= alignment_bytes);
    }

    const safety = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    const max_addr_bits = switch (safety) {
        true => 48, // Ensures space for Canary bits.
        false => 64,
    };
    const Size = @Int(.unsigned, @min(max_addr_bits, 64 - @bitSizeOf(Alignment), @bitSizeOf(usize)));
    const Canary = @Int(.unsigned, 64 - @bitSizeOf(Alignment) - @bitSizeOf(Size));
    const magic: Canary = switch (safety) {
        true => @truncate(@as(u64, 0x76fa65bebb3d7a39)), // statically chosen entropy
        false => 0,
    };

    fn get(base: [*]align(alignment_bytes) u8) Header {
        const header: *Header = @ptrCast(base - @sizeOf(Header));
        assert(header.canary == magic);
        return header.*;
    }

    fn set(base: [*]align(alignment_bytes) u8, a: Alignment, size: Size) [*]align(alignment_bytes) u8 {
        const header: *Header = @ptrCast(base - @sizeOf(Header));
        header.* = .{ .alignment = a, .size = size };
        return base;
    }
};

// ---------------------------------------------------------------------------
// Shared lock
// ---------------------------------------------------------------------------

/// Taken by every entry point below. Lives in linear memory, which is the part
/// of the module all worker instances share.
var lock: u32 = 0;

/// Real wasm atomics, spelled out in assembly: Zig compiles `@atomicRmw` and
/// friends to plain accesses when the target is single-threaded, which wasm
/// always is here, so the builtins would not order anything across workers.
inline fn atomicLoad(ptr: *u32) u32 {
    return asm volatile (
        \\local.get %[ptr]
        \\i32.atomic.load 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
        : .{ .memory = true });
}

inline fn atomicStore(ptr: *u32, value: u32) void {
    asm volatile (
        \\local.get %[ptr]
        \\local.get %[value]
        \\i32.atomic.store 0
        :
        : [ptr] "r" (ptr),
          [value] "r" (value),
        : .{ .memory = true });
}

inline fn atomicCompareExchange(ptr: *u32, expected: u32, desired: u32) u32 {
    return asm volatile (
        \\local.get %[ptr]
        \\local.get %[expected]
        \\local.get %[desired]
        \\i32.atomic.rmw.cmpxchg 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expected] "r" (expected),
          [desired] "r" (desired),
        : .{ .memory = true });
}

/// Number of entry points that had to wait, and the number that took the lock
/// without waiting. Exported for tests and for the leader's independent
/// verification that these definitions are the ones actually linked.
var lock_spins: u32 = 0;
var lock_entries: u32 = 0;

fn lockAcquire() void {
    atomicStore(&lock_entries, atomicLoad(&lock_entries) +% 1);
    var spins: u32 = 0;
    while (atomicCompareExchange(&lock, 0, 1) != 0) {
        spins +%= 1;
        std.atomic.spinLoopHint();
    }
    if (spins != 0) atomicStore(&lock_spins, atomicLoad(&lock_spins) +% spins);
}

fn lockRelease() void {
    atomicStore(&lock, 0);
}

// ---------------------------------------------------------------------------
// Allocator core (no locking: every caller holds the lock)
// ---------------------------------------------------------------------------

fn allocImpl(n: usize) ?[*]align(alignment_bytes) u8 {
    return allocAlignedImpl(alignment, n);
}

fn allocAlignedImpl(alloc_alignment: Alignment, n: usize) ?[*]align(alignment_bytes) u8 {
    const size = std.math.cast(Header.Size, n) orelse return nomem();
    const max_align = alignment.max(alloc_alignment);
    const max_align_bytes = max_align.toByteUnits();
    const ptr: [*]align(alignment_bytes) u8 = @alignCast(
        vtable.alloc(no_context, n + max_align_bytes, max_align, no_ra) orelse return nomem(),
    );
    const base: [*]align(alignment_bytes) u8 = @alignCast(ptr + max_align_bytes);
    return Header.set(base, max_align, size);
}

fn freeImpl(opt_old_base: ?[*]align(alignment_bytes) u8) void {
    const old_base = opt_old_base orelse return;
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    vtable.free(no_context, old_slice, old_alignment, no_ra);
}

fn reallocImpl(opt_old_base: ?[*]align(alignment_bytes) u8, n: usize) ?[*]align(alignment_bytes) u8 {
    if (n == 0) {
        freeImpl(opt_old_base);
        return null;
    }
    const old_base = opt_old_base orelse return allocImpl(n);
    const new_size = std.math.cast(Header.Size, n) orelse return nomem();
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    const new_base: [*]align(alignment_bytes) u8 = if (vtable.remap(
        no_context,
        old_slice,
        old_alignment,
        n + old_alignment_bytes,
        no_ra,
    )) |new_ptr| @alignCast(new_ptr + old_alignment_bytes) else b: {
        const new_ptr: [*]align(alignment_bytes) u8 = @alignCast(
            vtable.alloc(no_context, n + old_alignment_bytes, old_alignment, no_ra) orelse
                return nomem(),
        );
        const new_base: [*]align(alignment_bytes) u8 = @alignCast(new_ptr + old_alignment_bytes);
        const copy_len = @min(new_size, old_size);
        @memcpy(new_base[0..copy_len], old_base[0..copy_len]);
        vtable.free(no_context, old_slice, old_alignment, no_ra);
        break :b new_base;
    };
    return Header.set(new_base, old_alignment, new_size);
}

/// Libc memory allocation functions must set errno in addition to returning
/// `null`.
fn nomem() ?[*]align(alignment_bytes) u8 {
    @branchHint(.cold);
    std.c._errno().* = @intFromEnum(std.c.E.NOMEM);
    return null;
}

// ---------------------------------------------------------------------------
// Exported entry points (strong definitions overriding libc's weak ones)
// ---------------------------------------------------------------------------

export fn malloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return allocImpl(n);
}

export fn free(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) void {
    lockAcquire();
    defer lockRelease();
    freeImpl(opt_old_base);
}

export fn calloc(elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const n = std.math.mul(usize, elems, len) catch {
        lockAcquire();
        defer lockRelease();
        return nomem();
    };
    lockAcquire();
    defer lockRelease();
    // Not `allocImpl(n)` + memset outside the lock: zeroing is what makes
    // calloc's result usable, so it has to happen before another worker can
    // look at the block.
    const base = allocImpl(n) orelse return null;
    @memset(base[0..n], 0);
    return base;
}

export fn realloc(opt_old_base: ?[*]align(alignment_bytes) u8, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return reallocImpl(opt_old_base, n);
}

export fn reallocarray(opt_base: ?[*]align(alignment_bytes) u8, elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const n = std.math.mul(usize, elems, len) catch {
        lockAcquire();
        defer lockRelease();
        return nomem();
    };
    lockAcquire();
    defer lockRelease();
    return reallocImpl(opt_base, n);
}

export fn aligned_alloc(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return allocAlignedImpl(Alignment.fromByteUnits(alloc_alignment), n);
}

export fn posix_memalign(result: *?[*]align(alignment_bytes) u8, alloc_alignment: usize, n: usize) callconv(.c) c_int {
    if (alloc_alignment < @sizeOf(*anyopaque)) return @intFromEnum(std.c.E.INVAL);
    lockAcquire();
    defer lockRelease();
    result.* = allocAlignedImpl(Alignment.fromByteUnits(alloc_alignment), n) orelse
        return @intFromEnum(std.c.E.NOMEM);
    return 0;
}

export fn memalign(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return allocAlignedImpl(Alignment.fromByteUnits(alloc_alignment), n);
}

export fn valloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return allocAlignedImpl(alignment, n);
}

export fn malloc_usable_size(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) usize {
    const old_base = opt_old_base orelse return 0;
    lockAcquire();
    defer lockRelease();
    const old_header: Header = .get(old_base);
    return old_header.size;
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Entry points that ran, and the number of contended lock attempts they saw.
/// Both are exported so a test can prove these definitions are the linked ones:
/// an unlinked (libc) allocator would leave them at zero while the plugins
/// allocate.
export fn __emnapi_alloc_entries() callconv(.c) u32 {
    return atomicLoad(&lock_entries);
}

export fn __emnapi_alloc_spins() callconv(.c) u32 {
    return atomicLoad(&lock_spins);
}
