const std = @import("std");

pub const Stats = struct {
    alloc_calls: usize,
    free_calls: usize,
    active_allocations: isize,
    active_bytes: isize,
};

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: std.atomic.Value(usize) = .init(0),
    free_calls: std.atomic.Value(usize) = .init(0),
    active_allocations: std.atomic.Value(isize) = .init(0),
    active_bytes: std.atomic.Value(isize) = .init(0),

    const Self = @This();

    pub fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn stats(self: *Self) Stats {
        return .{
            .alloc_calls = self.alloc_calls.load(.monotonic),
            .free_calls = self.free_calls.load(.monotonic),
            .active_allocations = self.active_allocations.load(.monotonic),
            .active_bytes = self.active_bytes.load(.monotonic),
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;

        _ = self.alloc_calls.fetchAdd(1, .monotonic);
        _ = self.active_allocations.fetchAdd(1, .monotonic);
        _ = self.active_bytes.fetchAdd(@intCast(len), .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            return false;
        }

        _ = self.active_bytes.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        _ = self.active_bytes.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        _ = self.free_calls.fetchAdd(1, .monotonic);
        _ = self.active_allocations.fetchSub(1, .monotonic);
        _ = self.active_bytes.fetchSub(@intCast(memory.len), .monotonic);

        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
