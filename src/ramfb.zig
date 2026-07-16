// ramfb: QEMU's simplest display device. The guest allocates a linear
// framebuffer in its own RAM and announces it through the fw_cfg file
// "etc/ramfb" (all fields big-endian). Needs `-device ramfb` on the
// QEMU command line.

const std = @import("std");
const fwcfg = @import("fwcfg.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const console = @import("console.zig");

const XRGB8888: u32 = 0x34325258; // DRM fourcc 'XR24'

const Config = extern struct {
    addr: u64 align(1), // BE
    fourcc: u32 align(1), // BE
    flags: u32 align(1), // BE
    width: u32 align(1), // BE
    height: u32 align(1), // BE
    stride: u32 align(1), // BE
};

pub fn init(width: u32, height: u32) ?console.Framebuffer {
    const file = fwcfg.findFile("etc/ramfb") orelse return null;
    if (file.size != @sizeOf(Config)) return null;

    const stride = width * 4;
    const fb_bytes: usize = @as(usize, stride) * height;
    const pages = (fb_bytes + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;
    const fb_phys = mem.frames.allocContiguous(pages) orelse return null;

    const cfg = Config{
        .addr = @byteSwap(fb_phys),
        .fourcc = @byteSwap(XRGB8888),
        .flags = 0,
        .width = @byteSwap(width),
        .height = @byteSwap(height),
        .stride = @byteSwap(stride),
    };
    if (!fwcfg.dmaWrite(file.key, std.mem.asBytes(&cfg))) return null;

    return .{
        .address = @ptrFromInt(mmu.p2v(fb_phys)),
        .width = width,
        .height = height,
        .pitch = stride,
    };
}
