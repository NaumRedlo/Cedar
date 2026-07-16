// QEMU fw_cfg driver (MMIO flavour, compatible = "qemu,fw-cfg-mmio").
// fw_cfg is QEMU's guest-facing configuration channel: a selector picks
// a "file", the data port streams its bytes, and a DMA interface allows
// writes — which is how ramfb is told where our framebuffer lives.
// Register layout (docs/specs/fw_cfg.rst): data @+0, selector @+8 (BE),
// DMA address @+16 (BE, low-half write triggers).

const std = @import("std");
const mmu = @import("mmu.zig");

const SELECT_SIGNATURE: u16 = 0x0000;
const SELECT_FILE_DIR: u16 = 0x0019;

const CTL_ERROR: u32 = 0x01;
const CTL_READ: u32 = 0x02;
const CTL_SELECT: u32 = 0x08;
const CTL_WRITE: u32 = 0x10;

var base: u64 = 0;

fn dataPort() *volatile u8 {
    return @ptrFromInt(base);
}

fn selectorPort() *volatile u16 {
    return @ptrFromInt(base + 8);
}

fn dmaPort(off: u64) *volatile u32 {
    return @ptrFromInt(base + 16 + off);
}

fn select(key: u16) void {
    selectorPort().* = @byteSwap(key);
}

fn readByte() u8 {
    return dataPort().*;
}

fn readBe32() u32 {
    var v: u32 = 0;
    for (0..4) |_| v = (v << 8) | readByte();
    return v;
}

pub fn init(virt_base: u64) bool {
    base = virt_base;
    select(SELECT_SIGNATURE);
    var sig: [4]u8 = undefined;
    for (&sig) |*b| b.* = readByte();
    return std.mem.eql(u8, &sig, "QEMU");
}

pub const File = struct { key: u16, size: u32 };

pub fn findFile(name: []const u8) ?File {
    select(SELECT_FILE_DIR);
    const count = readBe32();
    for (0..count) |_| {
        const size = readBe32();
        const key: u16 = @intCast((@as(u32, readByte()) << 8) | readByte());
        _ = readByte();
        _ = readByte();
        var fname: [56]u8 = undefined;
        for (&fname) |*b| b.* = readByte();
        const end = std.mem.indexOfScalar(u8, &fname, 0) orelse 56;
        if (std.mem.eql(u8, fname[0..end], name)) {
            return .{ .key = key, .size = size };
        }
    }
    return null;
}

const DmaAccess = extern struct {
    control: u32, // BE
    length: u32, // BE
    address: u64, // BE
};

// Push `bytes` into the selected fw_cfg file (device consumes them).
pub fn dmaWrite(key: u16, bytes: []const u8) bool {
    var desc: DmaAccess align(16) = .{
        .control = @byteSwap((@as(u32, key) << 16) | CTL_SELECT | CTL_WRITE),
        .length = @byteSwap(@as(u32, @intCast(bytes.len))),
        .address = @byteSwap(mmu.v2p(@intFromPtr(bytes.ptr))),
    };
    const desc_phys = mmu.v2p(@intFromPtr(&desc));

    asm volatile ("dsb sy" ::: .{ .memory = true });
    dmaPort(0).* = @byteSwap(@as(u32, @intCast(desc_phys >> 32)));
    dmaPort(4).* = @byteSwap(@as(u32, @truncate(desc_phys)));
    asm volatile ("dsb sy" ::: .{ .memory = true });

    const ctl = @byteSwap(@as(*volatile u32, &desc.control).*);
    return (ctl & CTL_ERROR) == 0;
}
