// GICv2 driver (QEMU virt's default interrupt controller,
// compatible = "arm,cortex-a15-gic"). Distributor routes interrupts,
// the CPU interface delivers them to our core.

var gicd: [*]volatile u32 = undefined; // distributor
var gicc: [*]volatile u32 = undefined; // cpu interface

const GICD_CTLR = 0x000 / 4;
const GICD_ISENABLER = 0x100 / 4;
const GICD_ITARGETSR = 0x800; // byte per INTID: target CPU bitmask
const GICC_CTLR = 0x000 / 4;
const GICC_PMR = 0x004 / 4;
const GICC_IAR = 0x00c / 4;
const GICC_EOIR = 0x010 / 4;

pub const SPURIOUS: u32 = 1020; // intids >= 1020 mean "nothing pending"

// Distributor is global; program it once from the boot core, then bring
// this (boot) core's CPU interface up.
pub fn init(dist_base: u64, cpu_base: u64) void {
    gicd = @ptrFromInt(dist_base);
    gicc = @ptrFromInt(cpu_base);

    gicd[GICD_CTLR] = 1; // forward interrupts to CPU interfaces
    initCpu();
}

// The CPU interface is banked per-core: every core must enable its own
// (the MMIO address is the same, but each core sees its own bank).
pub fn initCpu() void {
    gicc[GICC_PMR] = 0xff; // priority mask: allow everything
    gicc[GICC_CTLR] = 1; // signal interrupts to this core
}

pub fn enableIrq(intid: u32) void {
    // Shared peripheral interrupts (>= 32) must be routed to a CPU
    // explicitly — the reset value targets no core, so under SMP they
    // would never be delivered. Send them all to cpu 0. (PPIs/SGIs
    // below 32 are per-core banked and need no targeting.)
    if (intid >= 32) {
        const targets: [*]volatile u8 = @ptrCast(gicd);
        targets[GICD_ITARGETSR + intid] = 0x01; // cpu 0
    }
    gicd[GICD_ISENABLER + intid / 32] = @as(u32, 1) << @intCast(intid % 32);
}

// Acknowledge: returns the pending interrupt id and starts servicing it.
pub fn ack() u32 {
    return gicc[GICC_IAR] & 0x3ff;
}

// End of interrupt: servicing done, allow this id to fire again.
pub fn eoi(intid: u32) void {
    gicc[GICC_EOIR] = intid;
}
