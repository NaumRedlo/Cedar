// Keyboard input over the PL011 RX interrupt: received bytes land in a
// ring buffer, a semaphore wakes whoever blocks in getChar(). The UART
// INTID comes from the device tree at init time.

const arch = @import("arch.zig").impl;
const gic = @import("gic.zig");
const sync = @import("sync.zig");

pub var intid: u32 = 0xffff_ffff; // set by init; matched in irq dispatch

var ring: [256]u8 = undefined;
var head: usize = 0; // write position (irq context)
var tail: usize = 0; // read position (thread context)
var available = sync.Semaphore{};

pub fn init(irq_intid: u32) void {
    intid = irq_intid;
    arch.enableUartRxIrq();
    gic.enableIrq(intid);
}

// IRQ context: drain the RX FIFO into the ring.
pub fn onIrq() void {
    while (arch.uartReadByte()) |b| {
        const next = (head + 1) % ring.len;
        if (next == tail) return; // full: drop the rest
        ring[head] = b;
        head = next;
        available.signal();
    }
}

// Thread context: block until a byte arrives.
pub fn getChar() u8 {
    available.wait();
    const daif = arch.irqSave();
    defer arch.irqRestore(daif);
    const b = ring[tail];
    tail = (tail + 1) % ring.len;
    return b;
}
