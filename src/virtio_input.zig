// Shared core for virtio-input devices (DeviceID 18) on the legacy
// virtio-mmio transport. The keyboard and the tablet are the same kind
// of device — an event queue of 8-byte evdev records — distinguished
// only by the name string in their config space. Each driver claims
// its device by name and supplies an event handler.

const std = @import("std");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");

// MMIO register offsets (legacy).
const MAGIC = 0x000 / 4;
const VERSION = 0x004 / 4;
const DEVICE_ID = 0x008 / 4;
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

// virtio-input config space (byte offsets from base + 0x100).
const CFG_SELECT = 0x100;
const CFG_SUBSEL = 0x101;
const CFG_SIZE = 0x102;
const CFG_DATA = 0x108;
const CFG_ID_NAME: u8 = 0x01;

const ST_ACKNOWLEDGE: u32 = 1;
const ST_DRIVER: u32 = 2;
const ST_DRIVER_OK: u32 = 4;
const ST_FEATURES_OK: u32 = 8;

const QUEUE_LEN = 32;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const F_WRITE: u16 = 2;

const UsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const Event = extern struct {
    kind: u16, // evdev type: 0 syn, 1 key, 3 abs
    code: u16,
    value: u32,
};

fn barrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

// If `base_virt` hosts a virtio-input device, copy its name into `buf`
// and return it. Only touches the config space — safe before claiming.
pub fn probeName(base_virt: u64, buf: []u8) ?[]u8 {
    const r = @as([*]volatile u32, @ptrFromInt(base_virt));
    if (r[MAGIC] != 0x74726976) return null;
    if (r[VERSION] != 1) return null;
    if (r[DEVICE_ID] != 18) return null;

    const sel = @as(*volatile u8, @ptrFromInt(base_virt + CFG_SELECT));
    const subsel = @as(*volatile u8, @ptrFromInt(base_virt + CFG_SUBSEL));
    const size = @as(*volatile u8, @ptrFromInt(base_virt + CFG_SIZE));
    sel.* = CFG_ID_NAME;
    subsel.* = 0;
    const n = @min(@as(usize, size.*), buf.len);
    for (0..n) |i| {
        buf[i] = @as(*volatile u8, @ptrFromInt(base_virt + CFG_DATA + i)).*;
    }
    return buf[0..n];
}

pub const Device = struct {
    regs: [*]volatile u32 = undefined,
    desc: [*]volatile Desc = undefined,
    avail_idx: *volatile u16 = undefined,
    avail_ring: [*]volatile u16 = undefined,
    used_idx: *volatile u16 = undefined,
    used_ring: [*]volatile UsedElem = undefined,
    last_used: u16 = 0,
    events: [QUEUE_LEN]Event align(16) = undefined,
    handler: *const fn (Event) void = undefined,

    pub fn init(self: *Device, base_virt: u64, handler: *const fn (Event) void) bool {
        const r = @as([*]volatile u32, @ptrFromInt(base_virt));
        self.regs = r;
        self.handler = handler;

        r[STATUS] = 0;
        r[STATUS] = ST_ACKNOWLEDGE;
        r[STATUS] |= ST_DRIVER;
        r[DRIVER_FEATURES] = 0;
        r[STATUS] |= ST_FEATURES_OK;
        r[GUEST_PAGE_SIZE] = mem.PAGE_SIZE;

        r[QUEUE_SEL] = 0; // eventq
        if (r[QUEUE_NUM_MAX] < QUEUE_LEN) return false;
        r[QUEUE_NUM] = QUEUE_LEN;
        r[QUEUE_ALIGN] = mem.PAGE_SIZE;

        const q_phys = mem.frames.allocContiguous(2) orelse return false;
        const q = @as([*]u8, @ptrFromInt(mmu.p2v(q_phys)));
        @memset(q[0 .. 2 * mem.PAGE_SIZE], 0);
        self.desc = @alignCast(@ptrCast(q));
        const avail = q + QUEUE_LEN * @sizeOf(Desc);
        self.avail_idx = @alignCast(@ptrCast(avail + 2));
        self.avail_ring = @alignCast(@ptrCast(avail + 4));
        self.used_idx = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 2));
        self.used_ring = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 4));
        r[QUEUE_PFN] = @intCast(q_phys / mem.PAGE_SIZE);

        // Hand every event buffer to the device up front.
        for (0..QUEUE_LEN) |i| {
            self.desc[i] = .{
                .addr = mmu.v2p(@intFromPtr(&self.events[i])),
                .len = @sizeOf(Event),
                .flags = F_WRITE,
                .next = 0,
            };
            self.avail_ring[i] = @intCast(i);
        }
        barrier();
        self.avail_idx.* = QUEUE_LEN;
        barrier();

        r[STATUS] |= ST_DRIVER_OK;
        r[QUEUE_NOTIFY] = 0;
        return true;
    }

    // IRQ context: drain completed events, recycle the buffers.
    pub fn onIrq(self: *Device) void {
        self.regs[INTERRUPT_ACK] = 0x3;
        while (self.last_used != self.used_idx.*) {
            // Acquire: the device writes the used_ring entry and only
            // then advances used_idx. Having observed the new used_idx,
            // barrier before reading the entry so we never see a stale
            // id. (Same ordering the block driver uses.)
            barrier();
            const id = self.used_ring[self.last_used % QUEUE_LEN].id;
            self.handler(self.events[id]);
            self.avail_ring[self.avail_idx.* % QUEUE_LEN] = @intCast(id);
            barrier();
            self.avail_idx.* +%= 1;
            self.last_used +%= 1;
        }
        barrier();
        self.regs[QUEUE_NOTIFY] = 0;
    }
};
