const std = @import("std");
const arch = @import("arch.zig").impl;

// Serial output is shared by threads and interrupt handlers; mask IRQs
// for the duration of a print so lines never interleave mid-character
// and the format buffer is never reentered.

pub fn kprint(s: []const u8) void {
    const daif = arch.irqSave();
    defer arch.irqRestore(daif);
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}

var fmt_buf: [512]u8 = undefined;

pub fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const daif = arch.irqSave();
    defer arch.irqRestore(daif);
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}
