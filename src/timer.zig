// ARM architectural timer, virtual flavour (CNTV): PPI with INTID 27.
// Counts at CNTFRQ_EL0 (62.5 MHz on QEMU virt); we program TVAL with
// one interval and re-arm it on every interrupt.

const log = @import("log.zig");
const gic = @import("gic.zig");

pub const INTID: u32 = 27;

var interval: u64 = 0;
var hz: u64 = 0;
pub var ticks: u64 = 0;

pub fn init(tick_hz: u64) void {
    const freq = asm volatile ("mrs %[out], cntfrq_el0"
        : [out] "=r" (-> u64),
    );
    hz = tick_hz;
    interval = freq / tick_hz;

    asm volatile (
        \\msr cntv_tval_el0, %[ival]
        \\mov x8, #1
        \\msr cntv_ctl_el0, x8
        :
        : [ival] "r" (interval),
        : .{ .x8 = true });

    gic.enableIrq(INTID);
    log.kprintf("timer: cntfrq {d} Hz, tick every {d} counts ({d} Hz)\n", .{ freq, interval, tick_hz });
}

// Volatile read: ticks is written from interrupt context.
pub fn now() u64 {
    return @as(*volatile u64, &ticks).*;
}

pub fn onIrq() void {
    ticks += 1;
    asm volatile ("msr cntv_tval_el0, %[ival]"
        :
        : [ival] "r" (interval),
    );
}
