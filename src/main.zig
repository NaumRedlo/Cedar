const std = @import("std");
const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("Cedar is ARM-only: aarch64 is the sole supported architecture"),
};

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    kprint("KERNEL PANIC: ");
    kprint(msg);
    kprint("\n");
    arch.halt();
}

fn kprint(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}

var fmt_buf: [256]u8 = undefined;

fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    kprint(s);
}

// Entered from boot.S on core 0, stack ready, BSS cleared, MMU off.
// dtb_phys is the device tree blob address QEMU passed in x0.
export fn kmain(dtb_phys: usize) callconv(.c) noreturn {
    arch.init();

    kprint("Hello, Cedar!\n\n");
    kprintf("boot: direct kernel image, no bootloader\n", .{});
    kprintf("dtb at: 0x{x}\n", .{dtb_phys});

    arch.halt();
}
