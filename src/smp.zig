// SMP bring-up: wake the secondary cores with PSCI and give each one a
// stack, exception vectors, its own timer and GIC CPU interface, then
// let it schedule from the shared thread table.

const std = @import("std");
const arch = @import("arch.zig").impl;
const mmu = @import("mmu.zig");
const mem = @import("mem.zig");
const sched = @import("sched.zig");
const timer = @import("timer.zig");
const gic = @import("gic.zig");
const exceptions = @import("exceptions.zig");
const log = @import("log.zig");

const MAX_CPUS = sched.MAX_CPUS;
const STACK_PAGES = 4;

// PSCI CPU_ON, SMC64 calling convention.
const PSCI_CPU_ON: u64 = 0xC400_0003;

extern const secondary_start: u8; // physical entry (linked in .text.boot)
export var secondary_stacks: [MAX_CPUS]u64 = @splat(0);

var online: u8 = 1;

// PSCI over HVC — the conduit QEMU's virt machine uses when the guest
// runs at EL1 (the `smc` conduit would need EL3, which we don't build
// for). Boards that declare method="smc" simply stay single-core here.
fn psci(function: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("hvc #0"
        : [ret] "={x0}" (-> u64),
        : [f] "{x0}" (function),
          [a] "{x1}" (a1),
          [b] "{x2}" (a2),
          [c] "{x3}" (a3),
        : .{ .memory = true, .x1 = true, .x2 = true, .x3 = true });
}

// `method` comes from the device tree /psci node.
pub fn startCores(method: []const u8, want: u8) void {
    if (!std.mem.eql(u8, method, "hvc")) {
        log.kprintf("smp: psci method '{s}' unsupported (need hvc), staying single-core\n", .{method});
        return;
    }
    // secondary_start lives in .text.boot, linked at its physical
    // address (VMA = LMA), so its symbol address IS the physical entry
    // PSCI needs — no v2p (same as mem.zig reads _start).
    const entry = @intFromPtr(&secondary_start);
    const n = @min(want, MAX_CPUS);

    var cpu: u8 = 1;
    while (cpu < n) : (cpu += 1) {
        const stack = mem.frames.allocContiguous(STACK_PAGES) orelse break;
        secondary_stacks[cpu] = mmu.p2v(stack + STACK_PAGES * mem.PAGE_SIZE);
        // Ensure the stack pointer is visible before the core reads it.
        asm volatile ("dsb sy" ::: .{ .memory = true });

        const ret = psci(PSCI_CPU_ON, cpu, entry, cpu);
        if (@as(i64, @bitCast(ret)) != 0) {
            log.kprintf("smp: cpu{d} CPU_ON failed ({d})\n", .{ cpu, @as(i64, @bitCast(ret)) });
        }
    }
}

// First code each secondary core runs (from boot.S, on its own stack).
export fn secondaryMain(cpu: u64) callconv(.c) noreturn {
    exceptions.install();
    gic.initCpu(); // this core's GIC CPU interface + priority mask
    sched.adoptIdle(cpu, idleName(cpu));

    _ = @atomicRmw(u8, &online, .Add, 1, .acq_rel);
    log.kprintf("smp: cpu{d} online at EL{d}\n", .{ cpu, arch.currentEl() });

    timer.initCpu(); // this core's virtual timer + tick IRQ
    arch.enableIrqs();

    // Nothing assigned yet: idle until the timer preempts us into a
    // thread the scheduler placed on this core.
    while (true) asm volatile ("wfi");
}

fn idleName(cpu: u64) []const u8 {
    return switch (cpu) {
        1 => "idle1",
        2 => "idle2",
        3 => "idle3",
        else => "idleN",
    };
}

pub fn onlineCount() u8 {
    return @atomicLoad(u8, &online, .acquire);
}
