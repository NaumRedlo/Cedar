// virtio-input keyboard (DeviceID 18) on the legacy virtio-mmio
// transport: the device fills 8-byte evdev-style events into buffers we
// keep queued. Key presses are translated through a US keymap and fed
// into the same input ring the UART uses — the shell can't tell typing
// in the QEMU window from typing in the terminal.

const std = @import("std");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const input = @import("input.zig");

// MMIO register offsets (legacy) — same layout as the blk driver.
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

const Event = extern struct {
    kind: u16, // evdev type: 0 syn, 1 key
    code: u16,
    value: u32, // 1 press, 0 release, 2 autorepeat
};

const EV_KEY = 1;
const KEY_LSHIFT = 42;
const KEY_RSHIFT = 54;

var regs: [*]volatile u32 = undefined;
var desc: [*]volatile Desc = undefined;
var avail_idx: *volatile u16 = undefined;
var avail_ring: [*]volatile u16 = undefined;
var used_idx: *volatile u16 = undefined;
var used_ring: [*]volatile UsedElem = undefined;
var last_used: u16 = 0;

var events: [QUEUE_LEN]Event align(16) = undefined;
var shift = false;

pub var present = false;
pub var intid: u32 = 0xffff_ffff;

pub fn probe(base_virt: u64, irq: u32) bool {
    if (present) return false;
    const r = @as([*]volatile u32, @ptrFromInt(base_virt));
    if (r[MAGIC] != 0x74726976) return false;
    if (r[VERSION] != 1) return false;
    if (r[DEVICE_ID] != 18) return false; // virtio-input

    regs = r;
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
    desc = @alignCast(@ptrCast(q));
    const avail = q + QUEUE_LEN * @sizeOf(Desc);
    avail_idx = @alignCast(@ptrCast(avail + 2));
    avail_ring = @alignCast(@ptrCast(avail + 4));
    used_idx = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 2));
    used_ring = @alignCast(@ptrCast(q + mem.PAGE_SIZE + 4));
    r[QUEUE_PFN] = @intCast(q_phys / mem.PAGE_SIZE);

    // Hand every event buffer to the device up front.
    for (0..QUEUE_LEN) |i| {
        desc[i] = .{
            .addr = mmu.v2p(@intFromPtr(&events[i])),
            .len = @sizeOf(Event),
            .flags = F_WRITE,
            .next = 0,
        };
        avail_ring[i] = @intCast(i);
    }
    barrier();
    avail_idx.* = QUEUE_LEN;
    barrier();

    r[STATUS] |= ST_DRIVER_OK;
    r[QUEUE_NOTIFY] = 0;

    intid = irq;
    present = true;
    return true;
}

fn barrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

// US layout, evdev keycodes 0..63.
const plain = [64]u8{
    0, 0, '1', '2', '3', '4', '5', '6', '7', '8', // 0-9
    '9', '0', '-', '=', 0x7f, '\t', 'q', 'w', 'e', 'r', // 10-19
    't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\r', 0, // 20-29
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 30-39
    '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', // 40-49
    'm', ',', '.', '/', 0, 0, 0, ' ', 0, 0, // 50-59
    0, 0, 0, 0, // 60-63
};

const shifted = [64]u8{
    0, 0, '!', '@', '#', '$', '%', '^', '&', '*', // 0-9
    '(', ')', '_', '+', 0x7f, '\t', 'Q', 'W', 'E', 'R', // 10-19
    'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\r', 0, // 20-29
    'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', // 30-39
    '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', // 40-49
    'M', '<', '>', '?', 0, 0, 0, ' ', 0, 0, // 50-59
    0, 0, 0, 0, // 60-63
};

fn handleEvent(ev: Event) void {
    if (ev.kind != EV_KEY) return;
    if (ev.code == KEY_LSHIFT or ev.code == KEY_RSHIFT) {
        shift = ev.value != 0;
        return;
    }
    if (ev.value == 0) return; // release
    if (ev.code >= plain.len) return;
    const c = if (shift) shifted[ev.code] else plain[ev.code];
    if (c != 0) input.pushByte(c);
}

// IRQ context: drain completed events, recycle the buffers.
pub fn onIrq() void {
    regs[INTERRUPT_ACK] = 0x3;
    barrier();
    while (last_used != used_idx.*) {
        const id = used_ring[last_used % QUEUE_LEN].id;
        handleEvent(events[id]);
        avail_ring[avail_idx.* % QUEUE_LEN] = @intCast(id);
        barrier();
        avail_idx.* +%= 1;
        last_used +%= 1;
    }
    barrier();
    regs[QUEUE_NOTIFY] = 0;
}
