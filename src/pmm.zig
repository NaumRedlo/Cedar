// Physical memory manager: a bitmap allocator over 4 KiB frames.
// Pure logic over a caller-provided bitmap slice, so it is fully
// unit-testable on the host (zig build test).

const std = @import("std");

pub const PAGE_SIZE: usize = 4096;

pub const FrameAllocator = struct {
    bitmap: []u8, // 1 bit per frame; set = used
    base: u64,
    frames: usize,
    free_count: usize,
    next: usize = 0, // next-fit cursor

    pub fn requiredBitmapBytes(ram_size: u64) usize {
        const n: usize = @intCast(ram_size / PAGE_SIZE);
        return (n + 7) / 8;
    }

    pub fn init(storage: []u8, base: u64, size: u64) FrameAllocator {
        const n: usize = @intCast(size / PAGE_SIZE);
        std.debug.assert(storage.len >= (n + 7) / 8);
        @memset(storage, 0);
        return .{ .bitmap = storage, .base = base, .frames = n, .free_count = n };
    }

    fn isUsed(self: *const FrameAllocator, i: usize) bool {
        return (self.bitmap[i / 8] >> @intCast(i % 8)) & 1 != 0;
    }

    fn setUsed(self: *FrameAllocator, i: usize) void {
        self.bitmap[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }

    fn setFree(self: *FrameAllocator, i: usize) void {
        self.bitmap[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
    }

    // Mark a physical range as unavailable; clamps to the managed RAM.
    pub fn reserveRange(self: *FrameAllocator, addr: u64, size: u64) void {
        if (size == 0 or self.frames == 0) return;
        const ram_end = self.base + @as(u64, self.frames) * PAGE_SIZE;
        const end = addr +| size;
        if (end <= self.base or addr >= ram_end) return;
        const lo = @max(addr, self.base);
        const hi = @min(end, ram_end);
        var i: usize = @intCast((lo - self.base) / PAGE_SIZE);
        const last: usize = @intCast((hi - 1 - self.base) / PAGE_SIZE);
        while (i <= last) : (i += 1) {
            if (!self.isUsed(i)) {
                self.setUsed(i);
                self.free_count -= 1;
            }
        }
    }

    pub fn alloc(self: *FrameAllocator) ?u64 {
        if (self.free_count == 0) return null;
        var scanned: usize = 0;
        var i = self.next;
        while (scanned < self.frames) : (scanned += 1) {
            if (i >= self.frames) i = 0;
            if (!self.isUsed(i)) {
                self.setUsed(i);
                self.free_count -= 1;
                self.next = i + 1;
                return self.base + @as(u64, i) * PAGE_SIZE;
            }
            i += 1;
        }
        return null;
    }

    pub fn allocContiguous(self: *FrameAllocator, count: usize) ?u64 {
        if (count == 0 or self.free_count < count) return null;
        var run: usize = 0;
        var i: usize = 0;
        while (i < self.frames) : (i += 1) {
            if (self.isUsed(i)) {
                run = 0;
                continue;
            }
            run += 1;
            if (run == count) {
                const first = i + 1 - count;
                for (first..i + 1) |j| self.setUsed(j);
                self.free_count -= count;
                return self.base + @as(u64, first) * PAGE_SIZE;
            }
        }
        return null;
    }

    pub fn free(self: *FrameAllocator, addr: u64) void {
        std.debug.assert(addr >= self.base);
        std.debug.assert((addr - self.base) % PAGE_SIZE == 0);
        const i: usize = @intCast((addr - self.base) / PAGE_SIZE);
        std.debug.assert(i < self.frames);
        std.debug.assert(self.isUsed(i)); // double free
        self.setFree(i);
        self.free_count += 1;
        if (i < self.next) self.next = i;
    }
};

const testing = std.testing;

fn testAllocator(storage: []u8) FrameAllocator {
    // 16 frames of RAM at 1 MiB.
    return FrameAllocator.init(storage, 0x100000, 16 * PAGE_SIZE);
}

test "alloc and free roundtrip" {
    var storage: [2]u8 = undefined;
    var fa = testAllocator(&storage);
    try testing.expectEqual(@as(usize, 16), fa.free_count);

    const f1 = fa.alloc().?;
    try testing.expectEqual(@as(u64, 0x100000), f1);
    const f2 = fa.alloc().?;
    try testing.expectEqual(@as(u64, 0x101000), f2);
    try testing.expectEqual(@as(usize, 14), fa.free_count);

    fa.free(f1);
    try testing.expectEqual(@as(usize, 15), fa.free_count);
    // freed frame is reused (next-fit cursor rewinds)
    try testing.expectEqual(f1, fa.alloc().?);
}

test "reserveRange excludes frames and clamps" {
    var storage: [2]u8 = undefined;
    var fa = testAllocator(&storage);
    // reserve two middle frames
    fa.reserveRange(0x102000, 2 * PAGE_SIZE);
    try testing.expectEqual(@as(usize, 14), fa.free_count);
    // partially overlapping + out-of-range reservations clamp safely
    fa.reserveRange(0, 0x100000 + PAGE_SIZE); // ends one frame into RAM
    fa.reserveRange(0x200000, PAGE_SIZE); // entirely outside
    try testing.expectEqual(@as(usize, 13), fa.free_count);
    // idempotent
    fa.reserveRange(0x102000, 2 * PAGE_SIZE);
    try testing.expectEqual(@as(usize, 13), fa.free_count);
}

test "allocContiguous finds a run across fragmentation" {
    var storage: [2]u8 = undefined;
    var fa = testAllocator(&storage);
    fa.reserveRange(0x101000, PAGE_SIZE); // hole at frame 1
    const run = fa.allocContiguous(4).?;
    try testing.expectEqual(@as(u64, 0x102000), run);
    fa.free(run);
    fa.free(run + PAGE_SIZE);
    // 16 total - 1 reserved - 4 allocated + 2 freed = 13
    try testing.expectEqual(@as(usize, 13), fa.free_count);
}

test "exhaustion returns null" {
    var storage: [2]u8 = undefined;
    var fa = testAllocator(&storage);
    for (0..16) |_| _ = fa.alloc().?;
    try testing.expectEqual(@as(?u64, null), fa.alloc());
    try testing.expectEqual(@as(?u64, null), fa.allocContiguous(1));
}

test "requiredBitmapBytes rounds up" {
    try testing.expectEqual(@as(usize, 2), FrameAllocator.requiredBitmapBytes(16 * PAGE_SIZE));
    try testing.expectEqual(@as(usize, 1), FrameAllocator.requiredBitmapBytes(3 * PAGE_SIZE));
    try testing.expectEqual(@as(usize, 65536), FrameAllocator.requiredBitmapBytes(2 << 30));
}
