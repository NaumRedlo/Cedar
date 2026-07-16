// Kernel memory bookkeeping: wires the frame allocator to real RAM.
// The bitmap lives immediately after the kernel image (page-aligned);
// reserved up front: the kernel itself (incl. boot stack and bitmap),
// the device tree blob, and every /memreserve/ entry from the DTB.

const std = @import("std");
const dtb = @import("dtb.zig");
const pmm = @import("pmm.zig");

pub var frames: pmm.FrameAllocator = undefined;

pub const PAGE_SIZE = pmm.PAGE_SIZE;

pub fn init(dt: *const dtb.Dtb, ram: dtb.Reg, dtb_phys: usize) void {
    const kernel_start = @intFromPtr(@extern([*]const u8, .{ .name = "_start" }));
    const stack_top = @intFromPtr(@extern([*]const u8, .{ .name = "__stack_top" }));

    const bitmap_addr = std.mem.alignForward(usize, stack_top, PAGE_SIZE);
    const bitmap_bytes = pmm.FrameAllocator.requiredBitmapBytes(ram.size);
    const storage = @as([*]u8, @ptrFromInt(bitmap_addr))[0..bitmap_bytes];

    frames = pmm.FrameAllocator.init(storage, ram.addr, ram.size);
    frames.reserveRange(kernel_start, (bitmap_addr + bitmap_bytes) - kernel_start);
    frames.reserveRange(dtb_phys, dt.raw.len);
    var rsv = dt.reservations();
    while (rsv.next()) |r| frames.reserveRange(r.addr, r.size);
}

pub fn freeMiB() u64 {
    return (@as(u64, frames.free_count) * PAGE_SIZE) >> 20;
}

pub fn totalMiB() u64 {
    return (@as(u64, frames.frames) * PAGE_SIZE) >> 20;
}
