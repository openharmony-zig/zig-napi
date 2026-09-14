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
//! Lock domains: this lock covers the `malloc` family and the `BrkAllocator`
//! instance compiled into *this* object. Zig code in the addon allocates through
//! `std.heap.page_allocator`, which on wasm is another `BrkAllocator`
//! instantiation with its own free lists, guarded by its own lock
//! (`src/napi/util/allocator.zig`); the two never touch the same free list.
//! They can only meet in `@wasmMemoryGrow`, which is a wasm atomic instruction
//! and hands out disjoint pages, so separate locks stay coherent — verified by
//! the mixed JS/worker allocation stress in `node-test/wasm/concurrency.test.cjs`
//! (blocks allocated on the JavaScript side keep their contents while workers
//! allocate and free through the addon).
//!
//! Locking rules:
//!
//! * One lock, taken exactly once per entry point. The `*Raw` helpers never call
//!   a public entry point, so `calloc` -> `malloc` and `realloc` ->
//!   `malloc`/`free` cannot deadlock on a non-recursive lock.
//! * The critical section is as small as correctness allows, but it is not a
//!   fixed handful of instructions: `BrkAllocator` can grow the linear memory
//!   inside it and `realloc` can copy the payload. It never calls back into
//!   JavaScript and never waits on another thread, so what it costs is bounded
//!   by that grow/copy, not by the host. `calloc` in particular zeroes *outside*
//!   the lock, because a freshly allocated block is private until it is
//!   returned.
//! * The lock never uses `memory.atomic.wait`: a blocking wait is not allowed on
//!   the JavaScript main thread, which also calls these functions. Spinning is
//!   the only option and every holder makes progress without the host.
//!
//! It is linked for *both* flavors. The single-threaded flavor needs no lock —
//! it has one thread and the lock compiles away — but it needs the same checked
//! size arithmetic and alignment validation: the overflow and huge-alignment
//! traps described below live in the backing allocator, not in the threading
//! model, and a single-threaded addon that calls `aligned_alloc(1 << 30, n)`
//! hits them just the same.
//!
//! ## Attribution
//!
//! The `Header` layout, the entry-point set and their libc semantics are
//! derived from Zig's `lib/c/malloc.zig` and `lib/c.zig`, which are
//! MIT licensed:
//!
//!     Copyright (c) Zig contributors
//!     Licensed under the MIT License (see https://ziglang.org/LICENSE)
//!
//! Added here: the shared lock, the checked size arithmetic, the POSIX
//! `posix_memalign` error contract and the page-aligned `valloc`.

const builtin = @import("builtin");
const std = @import("std");

const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const E = std.c.E;

/// Which allocator backs these entry points: the same `BrkAllocator` Zig's libc
/// uses for wasm (`std.heap.WasmAllocator`), so heap growth and the address
/// range are unchanged. This object has its *own* instance — Zig gives each
/// compilation unit its own `BrkAllocator.global`, and the addon's Zig code
/// keeps another one behind `std.heap.page_allocator` (see "Lock domains"
/// above) — so the two only share the atomic `@wasmMemoryGrow` that hands out
/// disjoint pages.
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

/// Whether the module can be entered by more than one thread. The threaded
/// flavor is built with the `atomics` CPU feature and shares its memory; the
/// single-threaded flavor is not, has exactly one thread, and compiles the lock
/// away entirely (no locking instruction is emitted there, atomic or not).
const needs_lock = std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);

/// Spin lock over this object's allocator. Lives in linear memory, which is the
/// part of the module all worker instances share.
///
/// `std.atomic.Mutex` is enough here: on this target Zig emits real wasm atomic
/// instructions for `@atomicRmw`/`@cmpxchgWeak` even though the module is built
/// `single_threaded`, which was verified rather than assumed — two worker realms
/// bumping one shared counter through `@atomicRmw`, `@cmpxchgWeak` and
/// `std.atomic.Mutex` all ended exactly at 2 × iterations, while an
/// unsynchronized control lost 142 483 of 400 000 updates.
var lock: std.atomic.Mutex = .unlocked;

/// Entry points that ran and the contended attempts they saw. Maintained while
/// the lock is held, so no increment can be lost; both are exported in every
/// flavor so a test can prove these definitions are the linked ones.
var lock_entries: u32 = 0;
var lock_spins: u32 = 0;

fn lockAcquire() void {
    if (!needs_lock) return;
    var spins: u32 = 0;
    while (!lock.tryLock()) {
        spins +%= 1;
        std.atomic.spinLoopHint();
    }
    lock_entries +%= 1;
    lock_spins +%= spins;
}

fn lockRelease() void {
    if (!needs_lock) return;
    lock.unlock();
}

// ---------------------------------------------------------------------------
// Allocator core
//
// Every `*Raw` function is called with the lock held and never calls a public
// entry point or touches `errno`.
// ---------------------------------------------------------------------------

/// Rejects the alignments libc may hand us but `Alignment` cannot represent:
/// zero and non powers of two. `Alignment.fromByteUnits` asserts a power of two,
/// so it must never see one of these.
fn representableAlignment(byte_count: usize) ?Alignment {
    if (byte_count == 0 or !std.math.isPowerOfTwo(byte_count)) return null;
    // An alignment larger than the class limit makes `BrkAllocator` index past
    // its big-class table even for a zero-size request (`alloc` uses
    // `@max(len, alignment)`), so it is rejected here as well.
    if (byte_count > max_class_bytes) return null;
    return Alignment.fromByteUnits(byte_count);
}

/// Page size `BrkAllocator` rounds its big requests to on wasm32 (64 KiB).
const bigpage_size: usize = @max(64 * 1024, std.heap.page_size_max);

/// Largest request class `std.heap.BrkAllocator` can serve on wasm32.
///
/// `allocBigPages` indexes `big_frees` with `log2(pow2_pages)` and that table
/// holds `log2(max_usize / bigpage_size) = log2((2^32 - 1) / 2^16) = 15` entries,
/// i.e. indices 0..14. A request that needs more than `2^14 = 16384` pages
/// therefore reads one past the end: an "index out of bounds" panic in
/// Debug/ReleaseSafe and an out-of-bounds read in ReleaseFast. `2^14` pages is
/// 2^30 bytes, so that is the largest class.
const max_class_bytes: usize = 1 << 30;

/// Largest request that is safe to hand to the allocator.
///
/// `BrkAllocator.alloc` rounds a request up by `@sizeOf(usize)` and then to whole
/// pages before deriving the class, so a request within one page of the class
/// limit would round *past* it — `malloc(2^30 - 4)`, for instance, needs 16385
/// pages and lands in the out-of-bounds class. One page of margin keeps every
/// accepted request inside the table.
const max_alloc_bytes: usize = max_class_bytes - bigpage_size;

/// Whether a request (size plus alignment padding, as handed to the allocator)
/// stays inside the classes the backing allocator can index.
fn requestFits(total: usize) bool {
    return total <= max_alloc_bytes;
}

fn allocRaw(n: usize) ?[*]align(alignment_bytes) u8 {
    return allocAlignedRaw(alignment, n);
}

fn allocAlignedRaw(alloc_alignment: Alignment, n: usize) ?[*]align(alignment_bytes) u8 {
    const size = std.math.cast(Header.Size, n) orelse return null;
    const max_align = alignment.max(alloc_alignment);
    const max_align_bytes = max_align.toByteUnits();
    // `n + max_align_bytes` overflows for sizes close to the address space
    // limit, and an absurd alignment makes the same sum overflow: both are
    // out-of-memory, not a programming error, so they must not trap in Debug or
    // ReleaseSafe builds.
    const total = std.math.add(usize, n, max_align_bytes) catch return null;
    if (!requestFits(total)) return null;
    const ptr: [*]align(alignment_bytes) u8 = @alignCast(
        vtable.alloc(no_context, total, max_align, no_ra) orelse return null,
    );
    const base: [*]align(alignment_bytes) u8 = @alignCast(ptr + max_align_bytes);
    return Header.set(base, max_align, size);
}

fn freeRaw(opt_old_base: ?[*]align(alignment_bytes) u8) void {
    const old_base = opt_old_base orelse return;
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    vtable.free(no_context, old_slice, old_alignment, no_ra);
}

/// Returns null only when the new block cannot be provided; the old block and
/// its payload are left untouched in that case.
fn reallocRaw(old_base: [*]align(alignment_bytes) u8, n: usize) ?[*]align(alignment_bytes) u8 {
    const new_size = std.math.cast(Header.Size, n) orelse return null;
    const old_header: Header = .get(old_base);
    const old_size = old_header.size;
    const old_alignment = old_header.alignment;
    const old_alignment_bytes = old_alignment.toByteUnits();
    const old_ptr = old_base - old_alignment_bytes;
    const old_slice = old_ptr[0 .. old_size + old_alignment_bytes];
    const total = std.math.add(usize, n, old_alignment_bytes) catch return null;
    if (!requestFits(total)) return null;
    const new_base: [*]align(alignment_bytes) u8 = if (vtable.remap(
        no_context,
        old_slice,
        old_alignment,
        total,
        no_ra,
    )) |new_ptr| @alignCast(new_ptr + old_alignment_bytes) else b: {
        const new_ptr: [*]align(alignment_bytes) u8 = @alignCast(
            vtable.alloc(no_context, total, old_alignment, no_ra) orelse return null,
        );
        const new_base: [*]align(alignment_bytes) u8 = @alignCast(new_ptr + old_alignment_bytes);
        const copy_len = @min(new_size, old_size);
        @memcpy(new_base[0..copy_len], old_base[0..copy_len]);
        vtable.free(no_context, old_slice, old_alignment, no_ra);
        break :b new_base;
    };
    return Header.set(new_base, old_alignment, new_size);
}

fn usableSizeRaw(opt_old_base: ?[*]align(alignment_bytes) u8) usize {
    const old_base = opt_old_base orelse return 0;
    const old_header: Header = .get(old_base);
    return old_header.size;
}

/// Libc memory allocation functions must set errno in addition to returning
/// `null`.
fn nomem() ?[*]align(alignment_bytes) u8 {
    @branchHint(.cold);
    std.c._errno().* = @intFromEnum(E.NOMEM);
    return null;
}

fn invalid() ?[*]align(alignment_bytes) u8 {
    @branchHint(.cold);
    std.c._errno().* = @intFromEnum(E.INVAL);
    return null;
}

// ---------------------------------------------------------------------------
// Exported entry points (strong definitions overriding libc's weak ones)
// ---------------------------------------------------------------------------

export fn malloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    lockAcquire();
    defer lockRelease();
    return allocRaw(n) orelse nomem();
}

export fn free(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) void {
    lockAcquire();
    defer lockRelease();
    freeRaw(opt_old_base);
}

export fn calloc(elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    // A multiplication overflow is out-of-memory, never a trap.
    const n = std.math.mul(usize, elems, len) catch return nomem();
    const base: [*]align(alignment_bytes) u8 = blk: {
        lockAcquire();
        defer lockRelease();
        break :blk allocRaw(n) orelse return nomem();
    };
    // The block is private until this function returns it, so zeroing happens
    // after the lock is released: a large calloc must not hold the heap lock for
    // the whole memset.
    @memset(base[0..n], 0);
    return base;
}

export fn realloc(opt_old_base: ?[*]align(alignment_bytes) u8, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    if (n == 0) {
        lockAcquire();
        defer lockRelease();
        freeRaw(opt_old_base);
        return null;
    }
    const old_base = opt_old_base orelse {
        lockAcquire();
        defer lockRelease();
        return allocRaw(n) orelse nomem();
    };
    lockAcquire();
    defer lockRelease();
    return reallocRaw(old_base, n) orelse nomem();
}

export fn reallocarray(opt_old_base: ?[*]align(alignment_bytes) u8, elems: usize, len: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const n = std.math.mul(usize, elems, len) catch return nomem();
    if (n == 0) {
        lockAcquire();
        defer lockRelease();
        freeRaw(opt_old_base);
        return null;
    }
    const old_base = opt_old_base orelse {
        lockAcquire();
        defer lockRelease();
        return allocRaw(n) orelse nomem();
    };
    lockAcquire();
    defer lockRelease();
    return reallocRaw(old_base, n) orelse nomem();
}

export fn aligned_alloc(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    // C11: an alignment the implementation cannot satisfy fails the call. A
    // non power of two (including zero) is such a case and must not reach
    // `Alignment.fromByteUnits`, which asserts.
    const requested = representableAlignment(alloc_alignment) orelse return invalid();
    lockAcquire();
    defer lockRelease();
    return allocAlignedRaw(requested, n) orelse nomem();
}

export fn posix_memalign(result: *?[*]align(alignment_bytes) u8, alloc_alignment: usize, n: usize) callconv(.c) c_int {
    // POSIX: the alignment must be a power of two multiple of `sizeof(void*)`,
    // and on failure the caller's pointer must be left alone; the error is the
    // return value, so errno is not touched.
    if (alloc_alignment < @sizeOf(*anyopaque)) return @intFromEnum(E.INVAL);
    const requested = representableAlignment(alloc_alignment) orelse return @intFromEnum(E.INVAL);
    const allocated = blk: {
        lockAcquire();
        defer lockRelease();
        break :blk allocAlignedRaw(requested, n);
    };
    if (allocated == null) return @intFromEnum(E.NOMEM);
    result.* = allocated;
    return 0;
}

export fn memalign(alloc_alignment: usize, n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    const requested = representableAlignment(alloc_alignment) orelse return invalid();
    lockAcquire();
    defer lockRelease();
    return allocAlignedRaw(requested, n) orelse nomem();
}

export fn valloc(n: usize) callconv(.c) ?[*]align(alignment_bytes) u8 {
    // `valloc` is page aligned, and a wasm page is 64 KiB — not the 16 bytes a
    // plain `malloc` guarantees. `std.heap.pageSize()` is that page size here.
    const page = comptime Alignment.fromByteUnits(std.heap.pageSize());
    lockAcquire();
    defer lockRelease();
    return allocAlignedRaw(page, n) orelse nomem();
}

export fn malloc_usable_size(opt_old_base: ?[*]align(alignment_bytes) u8) callconv(.c) usize {
    lockAcquire();
    defer lockRelease();
    return usableSizeRaw(opt_old_base);
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Exported so a test can prove these definitions are the linked ones: libc's
/// allocator would leave them at zero while the plugins allocate.
export fn __emnapi_alloc_entries() callconv(.c) u32 {
    lockAcquire();
    defer lockRelease();
    return lock_entries;
}

export fn __emnapi_alloc_spins() callconv(.c) u32 {
    lockAcquire();
    defer lockRelease();
    return lock_spins;
}
