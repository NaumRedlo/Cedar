// The first interactive thread: a tiny line-oriented shell on the
// kernel console (serial + framebuffer, whichever is attached).

const std = @import("std");
const log = @import("log.zig");
const input = @import("input.zig");
const timer = @import("timer.zig");
const mem = @import("mem.zig");
const console = @import("console.zig");
const fs = @import("fs.zig");
const sched = @import("sched.zig");
const user = @import("user.zig");
const heap = @import("heap.zig");
const arch = @import("arch.zig").impl;
const smp = @import("smp.zig");
const wm = @import("wm.zig");
const disk = @import("disk.zig");

const kprint = log.kprint;
const kprintf = log.kprintf;

pub fn run() callconv(.c) void {
    kprint("\nCedar shell. Type 'help'.\n");
    var buf: [128]u8 = undefined;

    while (true) {
        kprint("cedar> ");
        const line = readLine(&buf);
        execute(line);
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

fn execute(line: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return;

    if (std.mem.eql(u8, cmd, "help")) {
        kprint("system: help, about, uptime, mem, clear, ps, save, smp, spin, gui\n");
        kprint("files:  ls [path], cat <path>, write <path> <text>, mkdir <path>, rm <path>\n");
        kprint("proc:   run <path> [args...]\n");
    } else if (std.mem.eql(u8, cmd, "about")) {
        kprint("Cedar — an ARM-only hobby kernel in Zig. No bootloader, no mercy.\n");
    } else if (std.mem.eql(u8, cmd, "uptime")) {
        const t = timer.now();
        kprintf("up {d}.{d}s ({d} ticks)\n", .{ t / 10, t % 10, t });
    } else if (std.mem.eql(u8, cmd, "mem")) {
        kprintf("{d} MiB free of {d} MiB\n", .{ mem.freeMiB(), mem.totalMiB() });
    } else if (std.mem.eql(u8, cmd, "clear")) {
        console.clear();
    } else if (std.mem.eql(u8, cmd, "ls")) {
        cmdLs(it.next() orelse "/");
    } else if (std.mem.eql(u8, cmd, "cat")) {
        cmdCat(it.next() orelse return kprint("usage: cat <path>\n"));
    } else if (std.mem.eql(u8, cmd, "mkdir")) {
        cmdMkdir(it.next() orelse return kprint("usage: mkdir <path>\n"));
    } else if (std.mem.eql(u8, cmd, "rm")) {
        cmdRm(it.next() orelse return kprint("usage: rm <path>\n"));
    } else if (std.mem.eql(u8, cmd, "write")) {
        const path = it.next() orelse return kprint("usage: write <path> <text>\n");
        cmdWrite(path, std.mem.trimStart(u8, it.rest(), " "));
    } else if (std.mem.eql(u8, cmd, "ps")) {
        sched.ps();
    } else if (std.mem.eql(u8, cmd, "smp")) {
        kprintf("{d} cpu(s) online; this shell is on cpu{d}\n", .{ smp.onlineCount(), arch.cpuId() });
    } else if (std.mem.eql(u8, cmd, "spin")) {
        cmdSpin();
    } else if (std.mem.eql(u8, cmd, "gui")) {
        wm.start();
    } else if (std.mem.eql(u8, cmd, "save")) {
        if (disk.save()) |bytes| {
            kprintf("fs: snapshot saved, {d} bytes\n", .{bytes});
        } else |e| {
            kprintf("save: {s}\n", .{@errorName(e)});
        }
    } else if (std.mem.eql(u8, cmd, "run")) {
        cmdRun(&it);
    } else {
        kprintf("unknown command: '{s}' (try 'help')\n", .{cmd});
    }
}

fn fsReady() bool {
    if (!fs.ready) kprint("fs: not initialised\n");
    return fs.ready;
}

fn cmdLs(path: []const u8) void {
    if (!fsReady()) return;
    const node = fs.global.lookup(path) orelse return kprintf("ls: no such path: {s}\n", .{path});
    if (node.kind == .file) {
        kprintf("{d:>8}  {s}\n", .{ node.size(), node.name });
        return;
    }
    if (node.children.items.len == 0) return kprint("(empty)\n");
    for (node.children.items) |c| {
        switch (c.kind) {
            .dir => kprintf("     dir  {s}/  ({d} items)\n", .{ c.name, c.size() }),
            .file => kprintf("{d:>8}  {s}\n", .{ c.size(), c.name }),
        }
    }
}

fn cmdCat(path: []const u8) void {
    if (!fsReady()) return;
    const bytes = fs.global.read(path) catch |e| return kprintf("cat: {s}: {s}\n", .{ path, @errorName(e) });
    kprint(bytes);
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') kprint("\n");
}

fn cmdMkdir(path: []const u8) void {
    if (!fsReady()) return;
    _ = fs.global.mkdir(path) catch |e| return kprintf("mkdir: {s}: {s}\n", .{ path, @errorName(e) });
}

fn cmdRm(path: []const u8) void {
    if (!fsReady()) return;
    fs.global.remove(path) catch |e| return kprintf("rm: {s}: {s}\n", .{ path, @errorName(e) });
}

fn cmdWrite(path: []const u8, text: []const u8) void {
    if (!fsReady()) return;
    fs.global.write(path, text) catch |e| return kprintf("write: {s}: {s}\n", .{ path, @errorName(e) });
    kprintf("{d} bytes -> {s}\n", .{ text.len, path });
}

// Spawn a burst of worker threads. The scheduler spreads them across
// cores round-robin; each reports which cpu it woke up on, so parallel
// execution across cores is visible.
fn cmdSpin() void {
    for (0..4) |_| {
        sched.spawn("worker", spinWorker) catch |e| {
            kprintf("spin: {s}\n", .{@errorName(e)});
            return;
        };
    }
    kprint("spin: 4 workers spawned across the cores\n");
}

fn spinWorker() callconv(.c) void {
    // A little busy work, then report home — repeated so a worker that
    // gets migrated-free scheduling still shows a stable cpu.
    for (0..3) |round| {
        var acc: u64 = 0;
        for (0..2_000_000) |k| acc +%= k;
        std.mem.doNotOptimizeAway(acc);
        kprintf("worker on cpu{d}: round {d} done\n", .{ arch.cpuId(), round });
        sched.sleep(2);
    }
}

fn cmdRun(it: *std.mem.TokenIterator(u8, .scalar)) void {
    const path = it.next() orelse return kprint("usage: run <path> [args...]\n");
    if (!fsReady()) return;
    const bytes = fs.global.read(path) catch |e| return kprintf("run: {s}: {s}\n", .{ path, @errorName(e) });
    if (bytes.len == 0) return kprint("run: empty file\n");

    // argv[0] is the path, by convention; up to 7 more arguments. The
    // strings are copied onto the user stack inside load(), so the
    // shell's line buffer can be reused right after.
    var args: [8][]const u8 = undefined;
    args[0] = path;
    var argc: usize = 1;
    while (it.next()) |tok| {
        if (argc == args.len) break;
        args[argc] = tok;
        argc += 1;
    }

    const img = user.load(bytes, args[0..argc]) catch |e| return kprintf("run: load failed: {s}\n", .{@errorName(e)});
    // The shell's line buffer is reused; the process name must outlive it.
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const name = heap.allocator().dupe(u8, base) catch "user";
    sched.spawnUser(name, img) catch |e| {
        kprintf("run: spawn failed: {s}\n", .{@errorName(e)});
        return;
    };
    kprintf("run: '{s}' started at EL0\n", .{name});
}
