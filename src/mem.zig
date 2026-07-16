// Kernel memory bookkeeping: wires the frame allocator to real RAM.
// The bitmap lives immediately after the kernel image (page-aligned);
// reserved up front: the kernel itself (incl. boot stack and bitmap),
// the device tree blob, and every /memreserve/ entry from the DTB.

const std = @import("std");
const dtb = @import("dtb.zig");
const pmm = @import("pmm.zig");
const mmu = @import("mmu.zig");

pub var frames: pmm.FrameAllocator = undefined;

pub const PAGE_SIZE = pmm.PAGE_SIZE;

pub fn init(dt: *const dtb.Dtb, ram: dtb.Reg, dtb_virt: usize) void {
    // _start sits in .boot, which is linked at its physical address;
    // everything else is HHDM-virtual and converts via v2p.
    const kernel_start_phys = @intFromPtr(@extern([*]const u8, .{ .name = "_start" }));
    const stack_top_virt = @intFromPtr(@extern([*]const u8, .{ .name = "__stack_top" }));

    const bitmap_virt = std.mem.alignForward(usize, stack_top_virt, PAGE_SIZE);
    const bitmap_bytes = pmm.FrameAllocator.requiredBitmapBytes(ram.size);
    const storage = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bitmap_bytes];

    frames = pmm.FrameAllocator.init(storage, ram.addr, ram.size);
    frames.reserveRange(kernel_start_phys, mmu.v2p(bitmap_virt + bitmap_bytes) - kernel_start_phys);
    frames.reserveRange(mmu.BOOT_TABLE_PHYS, mmu.BOOT_TABLE_PAGES * PAGE_SIZE);
    frames.reserveRange(mmu.v2p(dtb_virt), dt.raw.len);
    var rsv = dt.reservations();
    while (rsv.next()) |r| frames.reserveRange(r.addr, r.size);
}

pub fn freeMiB() u64 {
    return (@as(u64, frames.free_count) * PAGE_SIZE) >> 20;
}

pub fn totalMiB() u64 {
    return (@as(u64, frames.frames) * PAGE_SIZE) >> 20;
}
