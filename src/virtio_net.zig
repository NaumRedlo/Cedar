// virtio-net over the legacy virtio-mmio transport. Two virtqueues:
// queue 0 receives, queue 1 transmits. RX buffers are posted up front
// and reprocessed on each interrupt; TX is synchronous under a lock so
// it is safe to call from both a thread (ping) and IRQ context (ARP/
// ICMP replies). Start QEMU with
//   -netdev user,id=net0 -device virtio-net-device,netdev=net0

const std = @import("std");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const net = @import("net.zig");
const sync = @import("sync.zig");
const arch = @import("arch.zig").impl;

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
const CONFIG = 0x100; // virtio_net_config { u8 mac[6]; ... }

const ST_ACKNOWLEDGE: u32 = 1;
const ST_DRIVER: u32 = 2;
const ST_DRIVER_OK: u32 = 4;
const ST_FEATURES_OK: u32 = 8;

const VIRTIO_NET_F_MAC: u32 = 1 << 5;

const QUEUE_LEN = 16;
const HDR_LEN = 10; // legacy virtio_net_hdr, no MRG_RXBUF
const BUF_LEN = 2048; // header + a full ethernet frame, comfortably

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const F_NEXT: u16 = 1;
const F_WRITE: u16 = 2;

const UsedElem = extern struct {
    id: u32,
    len: u32,
};

const Queue = struct {
    desc: [*]volatile Desc = undefined,
    avail_flags: *volatile u16 = undefined,
    avail_idx: *volatile u16 = undefined,
    avail_ring: [*]volatile u16 = undefined,
    used_idx: *volatile u16 = undefined,
    used_ring: [*]volatile UsedElem = undefined,
    last_used: u16 = 0,
    buffers: [*]u8 = undefined, // QUEUE_LEN * BUF_LEN, contiguous

    fn setup(self: *Queue, r: [*]volatile u32, sel: u32) bool {
        r[QUEUE_SEL] = sel;
        if (r[QUEUE_NUM_MAX] < QUEUE_LEN) return false;
        r[QUEUE_NUM] = QUEUE_LEN;
        r[QUEUE_ALIGN] = mem.PAGE_SIZE;

        const q_phys = mem.frames.allocContiguous(2) orelse return false;
        const q = @as([*]u8, @ptrFromInt(mmu.p2v(q_phys)));
        @memset(q[0 .. 2 * mem.PAGE_SIZE], 0);
        self.desc = @alignCast(@ptrCast(q));
        const avail = q + QUEUE_LEN * @sizeOf(Desc);
        self.avail_flags = @alignCast(@ptrCast(avail));
        self.avail_idx = @alignCast(@ptrCast(avail + 2));
        self.avail_ring = @alignCast(@ptrCast(avail + 4));
        self.used_idx = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 2));
        self.used_ring = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 4));
        r[QUEUE_PFN] = @intCast(q_phys / mem.PAGE_SIZE);

        // Data buffers: QUEUE_LEN * BUF_LEN contiguous bytes.
        const bytes = QUEUE_LEN * BUF_LEN;
        const pages = (bytes + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;
        const b_phys = mem.frames.allocContiguous(pages) orelse return false;
        self.buffers = @ptrFromInt(mmu.p2v(b_phys));
        return true;
    }

    fn bufPhys(self: *Queue, i: usize) u64 {
        return mmu.v2p(@intFromPtr(self.buffers + i * BUF_LEN));
    }
};

var regs: [*]volatile u32 = undefined;
var rxq = Queue{};
var txq = Queue{};
var tx_lock = sync.SpinLock{};

pub var present = false;

fn barrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

pub fn probe(base_virt: u64) bool {
    if (present) return false;
    const r = @as([*]volatile u32, @ptrFromInt(base_virt));
    if (r[MAGIC] != 0x74726976) return false;
    if (r[VERSION] != 1) return false;
    if (r[DEVICE_ID] != 1) return false; // network device
    regs = r;

    r[STATUS] = 0;
    r[STATUS] = ST_ACKNOWLEDGE;
    r[STATUS] |= ST_DRIVER;
    const feat = r[DEVICE_FEATURES];
    r[DRIVER_FEATURES] = feat & VIRTIO_NET_F_MAC; // just the MAC
    r[STATUS] |= ST_FEATURES_OK;
    r[GUEST_PAGE_SIZE] = mem.PAGE_SIZE;

    if (!rxq.setup(r, 0)) return false;
    if (!txq.setup(r, 1)) return false;

    // Post every RX buffer as a device-writable descriptor.
    for (0..QUEUE_LEN) |i| {
        rxq.desc[i] = .{ .addr = rxq.bufPhys(i), .len = BUF_LEN, .flags = F_WRITE, .next = 0 };
        rxq.avail_ring[i] = @intCast(i);
    }
    barrier();
    rxq.avail_idx.* = QUEUE_LEN;
    barrier();

    r[STATUS] |= ST_DRIVER_OK;
    r[QUEUE_NOTIFY] = 0; // kick the RX queue

    var m: net.Mac = undefined;
    const cfg = @as([*]volatile u8, @ptrFromInt(base_virt + CONFIG));
    for (0..6) |i| m[i] = cfg[i];
    net.setMac(m);
    net.transmit = &transmit;
    net.poll = &poll;
    present = true;
    return true;
}

// Synchronous transmit under a lock: build hdr + frame in a TX buffer,
// post it, notify, and poll the used ring until it completes. Safe from
// thread and IRQ context alike.
pub fn transmit(frame: []const u8) void {
    if (!present or frame.len > BUF_LEN - HDR_LEN) return;
    const daif = tx_lock.lock();
    defer tx_lock.unlock(daif);

    const slot = txq.avail_idx.* % QUEUE_LEN;
    const buf = txq.buffers + @as(usize, slot) * BUF_LEN;
    @memset(buf[0..HDR_LEN], 0); // zeroed virtio-net header
    @memcpy(buf[HDR_LEN .. HDR_LEN + frame.len], frame);

    txq.desc[slot] = .{ .addr = txq.bufPhys(slot), .len = @intCast(HDR_LEN + frame.len), .flags = 0, .next = 0 };
    txq.avail_ring[txq.avail_idx.* % QUEUE_LEN] = slot;
    barrier();
    txq.avail_idx.* +%= 1;
    barrier();
    regs[QUEUE_NOTIFY] = 1;

    var spins: u32 = 0;
    while (txq.used_idx.* == txq.last_used) : (spins += 1) {
        if (spins > 50_000_000) break;
    }
    txq.last_used = txq.used_idx.*;
    regs[INTERRUPT_ACK] = 0x3;
    barrier();
}

// IRQ context: hand each received frame to the stack, then re-post the
// buffer so the device can fill it again.
pub var intid: u32 = 0xffff_ffff;

var rx_lock = sync.SpinLock{};

// Drain every completed RX buffer into the stack, then re-post it. QEMU
// reliably advances the used ring whether or not it raises an interrupt,
// so both the IRQ handler and the poll loop call this; the lock keeps
// them from processing the same buffer twice.
fn drainRx() void {
    const daif = rx_lock.lock();
    defer rx_lock.unlock(daif);
    while (rxq.last_used != rxq.used_idx.*) {
        barrier();
        const elem = rxq.used_ring[rxq.last_used % QUEUE_LEN];
        const id = elem.id;
        const total: usize = @intCast(elem.len);
        if (total > HDR_LEN) {
            const buf = rxq.buffers + @as(usize, @intCast(id)) * BUF_LEN;
            net.rx(buf[HDR_LEN..total]);
        }
        rxq.avail_ring[rxq.avail_idx.* % QUEUE_LEN] = @intCast(id);
        barrier();
        rxq.avail_idx.* +%= 1;
        rxq.last_used +%= 1;
    }
    barrier();
    regs[QUEUE_NOTIFY] = 0;
}

// Called by net.zig from its wait loops.
pub fn poll() void {
    if (present) drainRx();
}

pub fn onIrq() void {
    regs[INTERRUPT_ACK] = 0x3;
    barrier();
    drainRx();
}
