// The first interactive thread: a tiny line-oriented shell on the
// kernel console (serial + framebuffer, whichever is attached).

const std = @import("std");
const log = @import("log.zig");
const input = @import("input.zig");
const timer = @import("timer.zig");
const mem = @import("mem.zig");
const console = @import("console.zig");

const kprint = log.kprint;
const kprintf = log.kprintf;

pub fn run() callconv(.c) void {
    kprint("\nCedar shell. Type 'help'.\n");
    var buf: [128]u8 = undefined;

    while (true) {
        kprint("cedar> ");
        const line = readLine(&buf);
        execute(std.mem.trim(u8, line, " \t"));
    }
}

fn readLine(buf: []u8) []u8 {
    var len: usize = 0;
    while (true) {
        const c = input.getChar();
        switch (c) {
            '\r', '\n' => {
                kprint("\n");
                return buf[0..len];
            },
            0x08, 0x7f => { // backspace / delete
                if (len > 0) {
                    len -= 1;
                    kprint("\x08 \x08");
                }
            },
            else => {
                if (c >= 0x20 and c < 0x7f and len < buf.len) {
                    buf[len] = c;
                    len += 1;
                    kprint(&[_]u8{c});
                }
            },
        }
    }
}

fn execute(cmd: []const u8) void {
    if (cmd.len == 0) return;
    if (std.mem.eql(u8, cmd, "help")) {
        kprint("commands: help, about, uptime, mem, clear\n");
    } else if (std.mem.eql(u8, cmd, "about")) {
        kprint("Cedar — an ARM-only hobby kernel in Zig. No bootloader, no mercy.\n");
    } else if (std.mem.eql(u8, cmd, "uptime")) {
        const t = timer.now();
        kprintf("up {d}.{d}s ({d} ticks)\n", .{ t / 10, t % 10, t });
    } else if (std.mem.eql(u8, cmd, "mem")) {
        kprintf("{d} MiB free of {d} MiB\n", .{ mem.freeMiB(), mem.totalMiB() });
    } else if (std.mem.eql(u8, cmd, "clear")) {
        console.clear();
    } else {
        kprintf("unknown command: '{s}' (try 'help')\n", .{cmd});
    }
}
