const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine.zig");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("Cedar does not support this architecture"),
};

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    serialWrite("KERNEL PANIC: ");
    serialWrite(msg);
    serialWrite("\n");
    arch.halt();
}

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}

// Fill the screen with a green-tinted gradient as visible proof of life.
fn paintFramebuffer() void {
    const resp = limine.framebuffer_request.response orelse return;
    if (resp.framebuffer_count < 1) return;
    const fb = resp.framebuffers.?[0];
    if (fb.bpp != 32) return;

    const pixels: [*]volatile u32 = @alignCast(@ptrCast(fb.address));
    const words_per_row = fb.pitch / 4;
    for (0..fb.height) |y| {
        const row = pixels + y * words_per_row;
        for (0..fb.width) |x| {
            const g: u32 = @intCast(64 + (x * 191) / fb.width);
            const b: u32 = @intCast((y * 127) / fb.height);
            row[x] = (0x22 << 16) | (g << 8) | b;
        }
    }
}

export fn kmain() callconv(.c) noreturn {
    if (!limine.baseRevisionSupported()) arch.halt();

    arch.init();
    paintFramebuffer();
    serialWrite("Hello, Cedar!\n");
    arch.halt();
}
