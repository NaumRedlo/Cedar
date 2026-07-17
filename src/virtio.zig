// virtio-blk over the legacy virtio-mmio transport (version 1), the
// flavour QEMU's virt machine exposes by default. Same shape as
// xv6-riscv's driver: one 8-entry virtqueue, synchronous three-
// descriptor requests (header / 512-byte data / status), completion by
// polling the used ring. Start QEMU with
//   -drive file=disk.img,if=none,format=raw,id=hd0
//   -device virtio-blk-device,drive=hd0

const std = @import("std");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const sched = @import("sched.zig");

pub const SECTOR = 512;

// MMIO register offsets (legacy).
const MAGIC = 0x000 / 4;
const VERSION = 0x004 / 4;
const DEVICE_ID = 0x008 / 4;
const DEVICE_FEATURES = 0x010 / 4;
const DRIVER_FEATURES = 0x020 / 4;
const GUEST_PAGE_SIZE = 0x028 / 4;
const QUEUE_SEL = 0x030 / 4;
const QUEUE_NUM_MAX = 0x034 / 4;
const QUEUE_NUM = 0x038 / 4;
const QUEUE_ALIGN = 0x03c / 4;
const QUEUE_PFN = 0x040 / 4;
const QUEUE_NOTIFY = 0x050 / 4;
const INTERRUPT_ACK = 0x064 / 4;
const STATUS = 0x070 / 4;
const CONFIG = 0x100; // byte offset: virtio_blk_config { u64 capacity; ... }

const ST_ACKNOWLEDGE: u32 = 1;
const ST_DRIVER: u32 = 2;
const ST_DRIVER_OK: u32 = 4;
const ST_FEATURES_OK: u32 = 8;

const QUEUE_LEN = 8;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const F_NEXT: u16 = 1;
const F_WRITE: u16 = 2; // device writes this buffer

const BLK_T_IN: u32 = 0; // read from disk
const BLK_T_OUT: u32 = 1; // write to disk

const ReqHeader = extern struct {
    kind: u32,
    reserved: u32 = 0,
    sector: u64,
};

var regs: [*]volatile u32 = undefined;
var desc: [*]volatile Desc = undefined;
var avail_idx: *volatile u16 = undefined;
var avail_ring: [*]volatile u16 = undefined;
var used_idx: *volatile u16 = undefined;
var last_used: u16 = 0;

var hdr: ReqHeader align(16) = undefined;
var status_byte: u8 align(16) = 0xff;

pub var present = false;
pub var capacity_sectors: u64 = 0;

fn barrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

// Probe one virtio-mmio slot; claims it if it hosts a block device.
pub fn probeBlk(base_virt: u64) bool {
    if (present) return false; // one disk is plenty for now
    const r = @as([*]volatile u32, @ptrFromInt(base_virt));
    if (r[MAGIC] != 0x74726976) return false;
    if (r[VERSION] != 1) return false; // legacy transport only
    if (r[DEVICE_ID] != 2) return false; // block device

    regs = r;
    r[STATUS] = 0;
    r[STATUS] = ST_ACKNOWLEDGE;
    r[STATUS] |= ST_DRIVER;
    _ = r[DEVICE_FEATURES];
    r[DRIVER_FEATURES] = 0; // no optional features needed
    r[STATUS] |= ST_FEATURES_OK;
    r[GUEST_PAGE_SIZE] = mem.PAGE_SIZE;

    r[QUEUE_SEL] = 0;
    if (r[QUEUE_NUM_MAX] < QUEUE_LEN) return false;
    r[QUEUE_NUM] = QUEUE_LEN;
    r[QUEUE_ALIGN] = mem.PAGE_SIZE;

    // Legacy layout: page 0 = descriptors + avail ring, page 1 = used.
    const q_phys = mem.frames.allocContiguous(2) orelse return false;
    const q = @as([*]u8, @ptrFromInt(mmu.p2v(q_phys)));
    @memset(q[0 .. 2 * mem.PAGE_SIZE], 0);
    desc = @alignCast(@ptrCast(q));
    const avail = q + QUEUE_LEN * @sizeOf(Desc);
    avail_idx = @alignCast(@ptrCast(avail + 2));
    avail_ring = @alignCast(@ptrCast(avail + 4));
    used_idx = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 2));
    r[QUEUE_PFN] = @intCast(q_phys / mem.PAGE_SIZE);

    r[STATUS] |= ST_DRIVER_OK;

    const cfg = @as([*]volatile u32, @ptrFromInt(base_virt + CONFIG));
    capacity_sectors = @as(u64, cfg[0]) | (@as(u64, cfg[1]) << 32);
    present = true;
    return true;
}

pub const IoError = error{ NoDisk, IoFailed, OutOfRange };

// One synchronous 512-byte request. Single caller at a time by design
// (the shell thread); completion is polled with a yield per spin.
fn request(kind: u32, sector: u64, buf: []u8) IoError!void {
    if (!present) return IoError.NoDisk;
    if (buf.len != SECTOR) return IoError.IoFailed;
    if (sector >= capacity_sectors) return IoError.OutOfRange;

    hdr = .{ .kind = kind, .sector = sector };
    status_byte = 0xff;

    const data_flags: u16 = if (kind == BLK_T_IN) F_NEXT | F_WRITE else F_NEXT;
    desc[0] = .{ .addr = mmu.v2p(@intFromPtr(&hdr)), .len = @sizeOf(ReqHeader), .flags = F_NEXT, .next = 1 };
    desc[1] = .{ .addr = mmu.v2p(@intFromPtr(buf.ptr)), .len = SECTOR, .flags = data_flags, .next = 2 };
    desc[2] = .{ .addr = mmu.v2p(@intFromPtr(&status_byte)), .len = 1, .flags = F_WRITE, .next = 0 };

    avail_ring[avail_idx.* % QUEUE_LEN] = 0;
    barrier();
    avail_idx.* +%= 1;
    barrier();
    regs[QUEUE_NOTIFY] = 0;

    var spins: u32 = 0;
    while (used_idx.* == last_used) : (spins += 1) {
        if (spins > 100_000_000) return IoError.IoFailed;
    }
    last_used = used_idx.*;
    regs[INTERRUPT_ACK] = 0x3;
    barrier();

    if (status_byte != 0) return IoError.IoFailed;
}

pub fn readSector(sector: u64, buf: []u8) IoError!void {
    return request(BLK_T_IN, sector, buf);
}

pub fn writeSector(sector: u64, buf: []u8) IoError!void {
    return request(BLK_T_OUT, sector, buf);
}
