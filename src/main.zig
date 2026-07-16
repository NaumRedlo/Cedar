const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine.zig");
const console = @import("console.zig");

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

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}

// Console first: the framebuffer is the guaranteed output channel, so a
// faulting serial write can never hide text that was already printable.
fn kprint(s: []const u8) void {
    console.write(s);
    serialWrite(s);
}

var fmt_buf: [256]u8 = undefined;

fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    kprint(s);
}

export fn kmain() callconv(.c) noreturn {
    if (!limine.baseRevisionSupported()) arch.halt();

    arch.init();
    _ = console.init();

    kprint("Hello, Cedar!\n\n");

    if (limine.framebuffer_request.response) |resp| {
        if (resp.framebuffer_count >= 1) {
            const fb = resp.framebuffers.?[0];
            kprintf("framebuffer: {d}x{d}, {d} bpp\n", .{ fb.width, fb.height, fb.bpp });
        }
    }
    if (limine.hhdm_request.response) |hhdm| {
        kprintf("hhdm offset: 0x{x}\n", .{hhdm.offset});
    }

    arch.halt();
}
