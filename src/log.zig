const std = @import("std");
const arch = @import("arch.zig").impl;
const console = @import("console.zig");
const sync = @import("sync.zig");

// Output goes to serial and, once the framebuffer console is up, to
// the screen as well. A spinlock (which also masks IRQs) guards every
// print: no mid-line interleaving between threads, interrupt handlers,
// or — since SMP — other cores; the format buffer is never reentered.

pub var console_enabled = false;

var lock = sync.SpinLock{};

fn emit(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') arch.serialWriteByte('\r');
        arch.serialWriteByte(c);
        if (console_enabled) console.putChar(c);
    }
}

pub fn kprint(s: []const u8) void {
    const daif = lock.lock();
    defer lock.unlock(daif);
    emit(s);
}

var fmt_buf: [512]u8 = undefined;

pub fn kprintf(comptime fmt: []const u8, args: anytype) void {
    const daif = lock.lock();
    defer lock.unlock(daif);
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch return;
    emit(s);
}
