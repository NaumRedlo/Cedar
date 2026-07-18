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

// Console state (the framebuffer target, cursor, scroll) is guarded by
// this same lock: kprint holds it around putChar, so anyone repointing
// the console (the window manager on GUI enter/exit) must hold it too,
// or a print on another core can tear the transition. Held only across
// the state change itself — never call back into kprint while holding.
pub fn acquireConsole() u64 {
    return lock.lock();
}

pub fn releaseConsole(daif: u64) void {
    lock.unlock(daif);
}

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
