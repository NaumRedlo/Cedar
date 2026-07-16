const std = @import("std");
const arch = @import("arch.zig").impl;
const console = @import("console.zig");

// Output goes to serial and, once the framebuffer console is up, to
// the screen as well. IRQs are masked for the duration of a print so
// lines never interleave mid-character and the format buffer is never
// reentered.

pub var console_enabled = false;

fn emit(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
        if (console_enabled) console.putChar(c);
    }
}

pub fn kprint(s: []const u8) void {
    const daif = arch.irqSave();
    defer arch.irqRestore(daif);
    emit(s);
}

var fmt_buf: [512]u8 = undefined;

pub fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const daif = arch.irqSave();
    defer arch.irqRestore(daif);
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    emit(s);
}
