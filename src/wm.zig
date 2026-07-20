// The Cedar window manager: a kernel thread that owns the screen while
// GUI mode is active. Full-scene composition into a back buffer every
// frame (25 Hz): desktop gradient, draggable windows, a top bar with a
// live clock and a close box, and the mouse cursor. The kernel console
// is redirected into the "Console" window for the duration — kprint
// and the shell keep working, inside the GUI.

const std = @import("std");
const gfx = @import("gfx.zig");
const console = @import("console.zig");
const mouse = @import("mouse.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const sched = @import("sched.zig");
const timer = @import("timer.zig");
const log = @import("log.zig");
const smp = @import("smp.zig");

const BAR_H: u32 = 28;
const DOCK_H: u32 = 30;
const TITLE_H: u32 = 22;
const BORDER: u32 = 2;
const DOCK_BTN_W: u32 = 150;

// windows[0] hosts the redirected kernel console; its content buffer is
// written by the shell thread, so its blit is taken under the console
// lock (see drawWindow).
const CONSOLE_WIN: usize = 0;

const COL_BAR: u32 = 0x1e3a2a;
const COL_BAR_TEXT: u32 = 0xd7e4d0;
const COL_CLOSE: u32 = 0x8c3a3a;
const COL_CHROME: u32 = 0x2c4c3a;
const COL_TITLE_FOCUS: u32 = 0x3a6c50; // active window title bar
const COL_TITLE_BLUR: u32 = 0x24382c; // inactive window title bar
const COL_TITLE_TEXT: u32 = 0xe8f0e8;
const COL_TITLE_TEXT_BLUR: u32 = 0x8fae9a;
const COL_DOCK: u32 = 0x16281d;
const COL_DOCK_BTN: u32 = 0x24402f;
const COL_DOCK_BTN_HI: u32 = 0x3a6c50;
const COL_DESK_TOP: u32 = 0x14261c;
const COL_DESK_BOT: u32 = 0x0a140e;

const Window = struct {
    x: i32,
    y: i32,
    surf: gfx.Surface, // content buffer
    title: []const u8,

    fn outerW(self: *const Window) u32 {
        return self.surf.w + 2 * BORDER;
    }
    fn outerH(self: *const Window) u32 {
        return self.surf.h + TITLE_H + 2 * BORDER;
    }
};

// Written by the shell thread (start) and the WM thread (run / close
// box), read across cores; accessed atomically so the transition is
// always visible. Only the single shell thread calls start(), so the
// guard is not a cross-core check-then-act.
var running = false;

fn isRunning() bool {
    return @atomicLoad(bool, &running, .acquire);
}

fn setRunning(v: bool) void {
    @atomicStore(bool, &running, v, .release);
}

var screen: gfx.Surface = undefined;
var back: gfx.Surface = undefined;
var windows: [3]Window = undefined;
var zorder = [3]usize{ 0, 1, 2 };
var inited = false;

var drag: ?struct { win: usize, dx: i32, dy: i32 } = null;
var prev_left = false;

fn allocSurface(w: u32, h: u32) ?gfx.Surface {
    const bytes = @as(usize, w) * h * 4;
    const pages = (bytes + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;
    const phys = mem.frames.allocContiguous(pages) orelse return null;
    return .{
        .px = @ptrFromInt(mmu.p2v(phys)),
        .w = w,
        .h = h,
        .stride = w,
    };
}

fn setupOnce() bool {
    if (inited) return true;
    const desc = console.screen_desc orelse return false;
    screen = gfx.Surface.fromConsoleFb(desc);
    back = allocSurface(screen.w, screen.h) orelse return false;

    windows[0] = .{ .x = 40, .y = 60, .title = "Console", .surf = allocSurface(640, 384) orelse return false };
    windows[1] = .{ .x = 720, .y = 80, .title = "System Monitor", .surf = allocSurface(264, 120) orelse return false };
    windows[2] = .{ .x = 700, .y = 280, .title = "About Cedar", .surf = allocSurface(280, 96) orelse return false };
    inited = true;
    return true;
}

pub fn start() void {
    if (isRunning()) {
        log.kprint("gui: already running\n");
        return;
    }
    if (!setupOnce()) {
        log.kprint("gui: no framebuffer\n");
        return;
    }

    // Redirect the console into its window synchronously, before the
    // compose thread (and, at boot, the shell) run — so the shell's
    // first prompt lands in the window with no cross-thread race. Held
    // under the console lock so a concurrent kprint can't tear the
    // framebuffer/cursor state mid-switch.
    {
        const daif = log.acquireConsole();
        defer log.releaseConsole(daif);
        const cw = &windows[CONSOLE_WIN].surf;
        console.init(.{
            .address = @ptrCast(cw.px),
            .width = cw.w,
            .height = cw.h,
            .pitch = cw.w * 4,
        });
    }
    drawAbout();
    log.kprint("Cedar desktop. The console lives in this window.\n");

    setRunning(true);
    sched.spawn("wm", run) catch |e| {
        setRunning(false);
        log.kprintf("gui: spawn failed: {s}\n", .{@errorName(e)});
    };
}

fn run() callconv(.c) void {
    while (isRunning()) {
        handleMouse();
        compose();
        sched.sleep(1); // one tick = one frame
    }

    // Console returns to the full screen (diagnostic mode), under the
    // console lock. Typing 'gui' brings the desktop back.
    {
        const daif = log.acquireConsole();
        defer log.releaseConsole(daif);
        console.init(console.screen_desc.?);
    }
    log.kprint("Dropped to the diagnostic console. Type 'gui' for the desktop.\n");
}

fn handleMouse() void {
    const st = mouse.state();
    const pressed = st.left and !prev_left;
    const released = !st.left;
    prev_left = st.left;

    if (released) drag = null;

    if (drag) |d| {
        windows[d.win].x = @as(i32, @intCast(st.x)) - d.dx;
        windows[d.win].y = @max(@as(i32, @intCast(st.y)) - d.dy, @as(i32, @intCast(BAR_H)));
        return;
    }
    if (!pressed) return;

    const mx: i32 = @intCast(st.x);
    const my: i32 = @intCast(st.y);

    // Close box in the top bar drops to the diagnostic console.
    if (my < BAR_H and mx >= screen.w - BAR_H) {
        setRunning(false);
        return;
    }

    // Dock buttons at the bottom raise + focus their window.
    if (my >= back.h - DOCK_H) {
        for (0..windows.len) |wi| {
            const bx: i32 = @intCast(8 + wi * (DOCK_BTN_W + 6));
            if (mx >= bx and mx < bx + @as(i32, @intCast(DOCK_BTN_W))) {
                raise(wi);
                return;
            }
        }
        return;
    }

    // Hit-test windows, topmost first.
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const wi = zorder[zi];
        const w = &windows[wi];
        const ow: i32 = @intCast(w.outerW());
        const oh: i32 = @intCast(w.outerH());
        if (mx >= w.x and mx < w.x + ow and my >= w.y and my < w.y + oh) {
            raise(wi);
            if (my < w.y + @as(i32, @intCast(TITLE_H + BORDER))) {
                drag = .{ .win = wi, .dx = mx - w.x, .dy = my - w.y };
            }
            return;
        }
    }
}

fn raise(wi: usize) void {
    var found: usize = 0;
    for (zorder, 0..) |z, i| {
        if (z == wi) found = i;
    }
    var i = found;
    while (i + 1 < zorder.len) : (i += 1) zorder[i] = zorder[i + 1];
    zorder[zorder.len - 1] = wi;
}

var fmt_buf: [96]u8 = undefined;

fn compose() void {
    // Desktop: vertical gradient.
    for (0..back.h) |y| {
        const t: u32 = @intCast(y * 255 / back.h);
        const r = (((COL_DESK_TOP >> 16) & 0xff) * (255 - t) + ((COL_DESK_BOT >> 16) & 0xff) * t) / 255;
        const g = (((COL_DESK_TOP >> 8) & 0xff) * (255 - t) + ((COL_DESK_BOT >> 8) & 0xff) * t) / 255;
        const b = ((COL_DESK_TOP & 0xff) * (255 - t) + (COL_DESK_BOT & 0xff) * t) / 255;
        const row = back.px + y * back.stride;
        @memset(row[0..back.w], (r << 16) | (g << 8) | b);
    }

    drawSysmon();

    for (zorder) |wi| drawWindow(wi);

    drawDock();

    // Top bar.
    back.rect(0, 0, back.w, BAR_H, COL_BAR);
    back.text(10, 10, "Cedar", COL_BAR_TEXT, null);
    const t = timer.now();
    const hz = timer.tickHz();
    const s = std.fmt.bufPrint(&fmt_buf, "up {d}s | {d} cpus", .{ t / hz, smp.onlineCount() }) catch "";
    back.text(@intCast(back.w - BAR_H - 8 - s.len * 8), 10, s, COL_BAR_TEXT, null);
    back.rect(@intCast(back.w - BAR_H), 0, BAR_H, BAR_H, COL_CLOSE);
    back.text(@intCast(back.w - BAR_H + 10), 10, "x", 0xffffff, null);

    drawCursor();

    screen.blit(0, 0, &back);
}

fn focused() usize {
    return zorder[zorder.len - 1];
}

fn drawWindow(wi: usize) void {
    const w = &windows[wi];
    const ow = w.outerW();
    const oh = w.outerH();
    const active = wi == focused();
    back.rect(w.x, w.y, ow, oh, COL_CHROME);
    back.rect(w.x + 1, w.y + 1, ow - 2, TITLE_H, if (active) COL_TITLE_FOCUS else COL_TITLE_BLUR);
    back.text(w.x + 8, w.y + 7, w.title, if (active) COL_TITLE_TEXT else COL_TITLE_TEXT_BLUR, null);
    const cy = w.y + @as(i32, @intCast(TITLE_H + BORDER)) - 1;
    if (wi == CONSOLE_WIN) {
        // The shell writes this buffer via putChar/scroll under the
        // console lock; take it around the read so the blit never
        // captures a half-drawn glyph or a mid-scroll buffer.
        const daif = log.acquireConsole();
        defer log.releaseConsole(daif);
        back.blit(w.x + BORDER, cy, &w.surf);
    } else {
        back.blit(w.x + BORDER, cy, &w.surf);
    }
    back.frame(w.x, w.y, ow, oh, if (active) 0x6fa080 else 0x3f5c4c);
}

fn drawDock() void {
    const dy: i32 = @intCast(back.h - DOCK_H);
    back.rect(0, dy, back.w, DOCK_H, COL_DOCK);
    back.rect(0, dy, back.w, 1, 0x3a5c48); // top edge highlight
    const foc = focused();
    for (windows, 0..) |w, wi| {
        const bx: i32 = @intCast(8 + wi * (DOCK_BTN_W + 6));
        const active = wi == foc;
        back.rect(bx, dy + 4, DOCK_BTN_W, DOCK_H - 8, if (active) COL_DOCK_BTN_HI else COL_DOCK_BTN);
        back.text(bx + 8, dy + 11, w.title, if (active) COL_TITLE_TEXT else COL_TITLE_TEXT_BLUR, null);
    }
}

fn drawSysmon() void {
    const s = &windows[1].surf;
    s.fill(0x101c14);
    var buf: [64]u8 = undefined;
    const hz = timer.tickHz();
    var y: i32 = 10;
    const l1 = std.fmt.bufPrint(&buf, "uptime  {d} s", .{timer.now() / hz}) catch "";
    s.text(10, y, l1, 0xd7e4d0, null);
    y += 16;
    const l2 = std.fmt.bufPrint(&buf, "free    {d} MiB", .{mem.freeMiB()}) catch "";
    s.text(10, y, l2, 0xd7e4d0, null);
    y += 16;
    const l3 = std.fmt.bufPrint(&buf, "total   {d} MiB", .{mem.totalMiB()}) catch "";
    s.text(10, y, l3, 0xd7e4d0, null);
    y += 16;
    const l4 = std.fmt.bufPrint(&buf, "cpus    {d} online", .{smp.onlineCount()}) catch "";
    s.text(10, y, l4, 0xd7e4d0, null);
    y += 16;
    const l5 = std.fmt.bufPrint(&buf, "ticks   {d}", .{timer.now()}) catch "";
    s.text(10, y, l5, 0xd7e4d0, null);
}

fn drawAbout() void {
    const s = &windows[2].surf;
    s.fill(0x101c14);
    s.text(10, 12, "Cedar OS 0.1 (aarch64)", 0xd7e4d0, null);
    s.text(10, 30, "no bootloader, no mercy", 0x8fae9a, null);
    s.text(10, 56, "drag titles - dock raises windows", 0x8fae9a, null);
    s.text(10, 72, "x (top right) -> diagnostic console", 0x8fae9a, null);
}

// A simple 8x12 arrow, white with dark outline.
const cursor_rows = [12]u12{
    0b100000000000,
    0b110000000000,
    0b111000000000,
    0b111100000000,
    0b111110000000,
    0b111111000000,
    0b111111100000,
    0b111111110000,
    0b111110000000,
    0b110011000000,
    0b100011000000,
    0b000001100000,
};

fn drawCursor() void {
    const st = mouse.state();
    const cx: i32 = @intCast(st.x);
    const cy: i32 = @intCast(st.y);
    for (cursor_rows, 0..) |bits, ry| {
        for (0..12) |rx| {
            if ((bits >> @intCast(11 - rx)) & 1 == 0) continue;
            // outline: paint neighbors dark first pass isn't worth it;
            // draw dark shadow one pixel offset, then white pixel.
            back.rect(cx + @as(i32, @intCast(rx)) + 1, cy + @as(i32, @intCast(ry)) + 1, 1, 1, 0x0a140e);
            back.rect(cx + @as(i32, @intCast(rx)), cy + @as(i32, @intCast(ry)), 1, 1, 0xffffff);
        }
    }
}
