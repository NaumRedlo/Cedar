const log = @import("log.zig");
const arch = @import("arch.zig").impl;
const gic = @import("gic.zig");
const timer = @import("timer.zig");

extern var exception_vectors: u8;

// Must match the frame built in vectors.S (272 bytes).
pub const Frame = extern struct {
    x: [31]u64,
    elr: u64,
    spsr: u64,
    _pad: u64 = 0,
};

pub fn install() void {
    asm volatile (
        \\msr vbar_el1, %[addr]
        \\isb
        :
        : [addr] "r" (@intFromPtr(&exception_vectors)),
    );
}

fn mrs(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %[out], " ++ reg
        : [out] "=r" (-> u64),
    );
}

const vector_names = [16][]const u8{
    "sync / current EL, SP_EL0",
    "irq / current EL, SP_EL0",
    "fiq / current EL, SP_EL0",
    "serror / current EL, SP_EL0",
    "sync / current EL, SP_ELx",
    "irq / current EL, SP_ELx",
    "fiq / current EL, SP_ELx",
    "serror / current EL, SP_ELx",
    "sync / lower EL, aarch64",
    "irq / lower EL, aarch64",
    "fiq / lower EL, aarch64",
    "serror / lower EL, aarch64",
    "sync / lower EL, aarch32",
    "irq / lower EL, aarch32",
    "fiq / lower EL, aarch32",
    "serror / lower EL, aarch32",
};

fn ecName(ec: u64) []const u8 {
    return switch (ec) {
        0x00 => "unknown",
        0x0e => "illegal execution state",
        0x15 => "svc (aarch64)",
        0x18 => "msr/mrs trap",
        0x20 => "instruction abort, lower EL",
        0x21 => "instruction abort, current EL",
        0x22 => "pc alignment fault",
        0x24 => "data abort, lower EL",
        0x25 => "data abort, current EL",
        0x26 => "sp alignment fault",
        0x2f => "serror",
        0x30, 0x31 => "breakpoint",
        0x3c => "brk (aarch64)",
        else => "?",
    };
}

// Called from vectors.S. Returning resumes the interrupted code via eret.
export fn handleException(index: u64, frame: *Frame) callconv(.c) void {
    switch (index & 15) {
        1, 5 => dispatchIrq(),
        else => fatal(index & 15, frame),
    }
}

fn dispatchIrq() void {
    while (true) {
        const intid = gic.ack();
        if (intid >= gic.SPURIOUS) return;
        if (intid == timer.INTID) {
            timer.onIrq();
        } else {
            log.kprintf("irq: unexpected intid {d}\n", .{intid});
        }
        gic.eoi(intid);
    }
}

fn fatal(index: u64, frame: *const Frame) noreturn {
    const esr = mrs("esr_el1");
    const far = mrs("far_el1");
    const ec = (esr >> 26) & 0x3f;

    log.kprintf("\nEXCEPTION: {s}\n", .{vector_names[index & 15]});
    log.kprintf("  class: {s} (EC=0x{x:0>2})\n", .{ ecName(ec), ec });
    log.kprintf("  esr:  0x{x:0>16}  spsr: 0x{x:0>16}\n", .{ esr, frame.spsr });
    log.kprintf("  elr:  0x{x:0>16}  far:  0x{x:0>16}\n", .{ frame.elr, far });

    var i: usize = 0;
    while (i < 30) : (i += 2) {
        log.kprintf("  x{d:<2} 0x{x:0>16}  x{d:<2} 0x{x:0>16}\n", .{ i, frame.x[i], i + 1, frame.x[i + 1] });
    }
    log.kprintf("  x30 0x{x:0>16}\n", .{frame.x[30]});

    log.kprint("halted.\n");
    arch.halt();
}
