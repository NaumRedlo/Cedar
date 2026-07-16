const std = @import("std");
const build_options = @import("build_options");
const arch = @import("arch.zig").impl;
const log = @import("log.zig");
const exceptions = @import("exceptions.zig");

const kprint = log.kprint;
const kprintf = log.kprintf;

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    kprint("KERNEL PANIC: ");
    kprint(msg);
    kprint("\n");
    arch.halt();
}

// Entered from boot.S on core 0, stack ready, BSS cleared, MMU off.
// dtb_phys is the device tree blob address QEMU passed in x0.
export fn kmain(dtb_phys: usize) callconv(.c) noreturn {
    arch.init();
    exceptions.install();

    kprint("Hello, Cedar!\n\n");
    kprintf("boot: direct kernel image, no bootloader\n", .{});
    kprintf("dtb at: 0x{x}\n", .{dtb_phys});
    kprintf("exception vectors: installed (VBAR_EL1)\n", .{});

    if (build_options.test_exception) {
        kprint("\ntriggering brk #0 to exercise the exception path...\n");
        asm volatile ("brk #0");
    }

    arch.halt();
}
