const std = @import("std");
const arch = @import("arch.zig").impl;

pub fn kprint(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
    }
}

var fmt_buf: [512]u8 = undefined;

pub fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    kprint(s);
}
