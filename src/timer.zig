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
    interval = freq / tick_hz; // shared: CNTFRQ is the same on every core
    initCpu();
    log.kprintf("timer: cntfrq {d} Hz, tick every {d} counts ({d} Hz)\n", .{ freq, interval, tick_hz });
}

// The virtual timer is per-core: each core arms its own CNTV and enables
// the timer PPI on its own (banked) GIC interface.
pub fn initCpu() void {
    asm volatile (
        \\msr cntv_tval_el0, %[ival]
        \\mov x8, #1
        \\msr cntv_ctl_el0, x8
        :
        : [ival] "r" (interval),
        : .{ .x8 = true });
    gic.enableIrq(INTID);
}

// Volatile read: ticks is written from interrupt context. Only cpu 0
// increments it, so it stays a coherent single-writer clock.
pub fn now() u64 {
    return @as(*volatile u64, &ticks).*;
}

pub fn tickHz() u64 {
    return hz;
}

// Every core re-arms its own timer; only cpu 0 advances the shared tick
// counter, keeping `now()` a single-writer monotonic clock.
pub fn onIrq(is_bsp: bool) void {
    if (is_bsp) ticks += 1;
    asm volatile ("msr cntv_tval_el0, %[ival]"
        :
        : [ival] "r" (interval),
    );
}
