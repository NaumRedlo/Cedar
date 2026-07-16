// GICv2 driver (QEMU virt's default interrupt controller,
// compatible = "arm,cortex-a15-gic"). Distributor routes interrupts,
// the CPU interface delivers them to our core.

var gicd: [*]volatile u32 = undefined; // distributor
var gicc: [*]volatile u32 = undefined; // cpu interface

const GICD_CTLR = 0x000 / 4;
const GICD_ISENABLER = 0x100 / 4;
const GICC_CTLR = 0x000 / 4;
const GICC_PMR = 0x004 / 4;
const GICC_IAR = 0x00c / 4;
const GICC_EOIR = 0x010 / 4;

pub const SPURIOUS: u32 = 1020; // intids >= 1020 mean "nothing pending"

pub fn init(dist_base: u64, cpu_base: u64) void {
    gicd = @ptrFromInt(dist_base);
    gicc = @ptrFromInt(cpu_base);

    gicd[GICD_CTLR] = 1; // forward interrupts to CPU interfaces
    gicc[GICC_PMR] = 0xff; // priority mask: allow everything
    gicc[GICC_CTLR] = 1; // signal interrupts to this core
}

pub fn enableIrq(intid: u32) void {
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
