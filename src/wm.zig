// The Cedar window manager: a kernel thread that owns the screen. The
// desktop is the only surface — there is no way out to a full-screen
// console; the terminal is just a window you can close and reopen. Full
// scene composition into a back buffer every frame (25 Hz): desktop
// gradient, draggable/closable windows with shadows, a top bar with a
// live clock, a dock, and the mouse cursor. The kernel console is
// redirected into the "Console" window, so kprint and the shell keep
// working inside the GUI. Layout adapts to the screen resolution.

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

const BAR_H: u32 = 30;
const DOCK_H: u32 = 40;
const TITLE_H: u32 = 24;
const BORDER: u32 = 2;
const SHADOW: i32 = 8;
const MARGIN: u32 = 18;
const DOCK_BTN_W: u32 = 168;
const DOCK_BTN_GAP: u32 = 8;

// windows[0] hosts the redirected kernel console; its content buffer is
// written by the shell thread, so its blit is taken under the console
// lock (see drawWindow).
const CONSOLE_WIN: usize = 0;
const NWIN = 3;

// Palette — a calm cedar-green desktop.
const COL_BAR: u32 = 0x16281d;
const COL_BAR_TEXT: u32 = 0xd7e4d0;
const COL_BAR_ACCENT: u32 = 0x5fae7f;
const COL_CHROME: u32 = 0x22382b;
const COL_TITLE_FOCUS: u32 = 0x356048;
const COL_TITLE_BLUR: u32 = 0x21362a;
const COL_TITLE_TEXT: u32 = 0xeef4ee;
const COL_TITLE_TEXT_BLUR: u32 = 0x86a493;
const COL_WCLOSE: u32 = 0xb05a4e;
const COL_FRAME_FOCUS: u32 = 0x6fa080;
const COL_FRAME_BLUR: u32 = 0x33503f;
const COL_SHADOW: u32 = 0x05100a;
const COL_DOCK: u32 = 0x101d15;
const COL_DOCK_EDGE: u32 = 0x3a5c48;
const COL_DOCK_BTN: u32 = 0x21402e;
const COL_DOCK_BTN_HI: u32 = 0x356048;
const COL_DOCK_BTN_OFF: u32 = 0x18271d;
const COL_PANEL_BG: u32 = 0x0f1a13;
const COL_TEXT: u32 = 0xd7e4d0;
const COL_TEXT_DIM: u32 = 0x86a493;
const COL_DESK_TOP: u32 = 0x16301f;
const COL_DESK_BOT: u32 = 0x080f0a;

const Window = struct {
    x: i32,
    y: i32,
    surf: gfx.Surface, // content buffer
    title: []const u8,
    visible: bool = true,

    fn outerW(self: *const Window) u32 {
        return self.surf.w + 2 * BORDER;
    }
    fn outerH(self: *const Window) u32 {
        return self.surf.h + TITLE_H + 2 * BORDER;
    }
};

var running = false;

fn isRunning() bool {
    return @atomicLoad(bool, &running, .acquire);
}

fn setRunning(v: bool) void {
    @atomicStore(bool, &running, v, .release);
}

var screen: gfx.Surface = undefined;
var back: gfx.Surface = undefined;
var windows: [NWIN]Window = undefined;
var zorder = [NWIN]usize{ 0, 1, 2 };
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

// Content-buffer dimensions for a window whose outer box is ow x oh.
fn contentW(ow: u32) u32 {
    return ow - 2 * BORDER;
}
fn contentH(oh: u32) u32 {
    return oh - TITLE_H - 2 * BORDER;
}

fn setupOnce() bool {
    if (inited) return true;
    const desc = console.screen_desc orelse return false;
    screen = gfx.Surface.fromConsoleFb(desc);
    back = allocSurface(screen.w, screen.h) orelse return false;

    // Layout relative to the screen: the console takes the left column,
    // the info panels stack in a right column.
    const sw = screen.w;
    const sh = screen.h;
    const top = BAR_H + MARGIN;
    const bottom = sh - DOCK_H - MARGIN;
    const right_w: u32 = 340;
    const left_x: i32 = @intCast(MARGIN);
    const left_w = sw - right_w - 3 * MARGIN;
    const right_x: i32 = @intCast(sw - right_w - MARGIN);
    const usable_h = bottom - top;

    windows[0] = .{
        .x = left_x,
        .y = @intCast(top),
        .title = "Console",
        .surf = allocSurface(contentW(left_w), contentH(usable_h)) orelse return false,
    };
    windows[1] = .{
        .x = right_x,
        .y = @intCast(top),
        .title = "System Monitor",
        .surf = allocSurface(contentW(right_w), contentH(190)) orelse return false,
    };
    windows[2] = .{
        .x = right_x,
        .y = @intCast(top + 190 + MARGIN),
        .title = "About Cedar",
        .surf = allocSurface(contentW(right_w), contentH(150)) orelse return false,
    };
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
    // first prompt lands in the window with no cross-thread race.
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
    // The desktop is the only surface: this loop never exits.
    while (isRunning()) {
        handleMouse();
        compose();
        sched.sleep(1); // one tick = one frame
    }
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

    // Dock buttons toggle a window's visibility and raise it.
    if (my >= @as(i32, @intCast(back.h - DOCK_H))) {
        var wi: usize = 0;
        while (wi < NWIN) : (wi += 1) {
            const bx: i32 = @intCast(MARGIN + wi * (DOCK_BTN_W + DOCK_BTN_GAP));
            if (mx >= bx and mx < bx + @as(i32, @intCast(DOCK_BTN_W))) {
                if (windows[wi].visible and wi == focused()) {
                    windows[wi].visible = false; // click the active one to hide
                } else {
                    windows[wi].visible = true;
                    raise(wi);
                }
                return;
            }
        }
        return;
    }

    // Hit-test windows, topmost first (only visible ones).
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const wi = zorder[zi];
        const w = &windows[wi];
        if (!w.visible) continue;
        const ow: i32 = @intCast(w.outerW());
        const oh: i32 = @intCast(w.outerH());
        if (mx >= w.x and mx < w.x + ow and my >= w.y and my < w.y + oh) {
            raise(wi);
            // The close button occupies the right of the title bar.
            const cbx = w.x + ow - @as(i32, @intCast(TITLE_H));
            if (my < w.y + @as(i32, @intCast(TITLE_H)) and mx >= cbx) {
                w.visible = false;
                return;
            }
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

// Topmost visible window.
fn focused() usize {
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        if (windows[zorder[zi]].visible) return zorder[zi];
    }
    return zorder[zorder.len - 1];
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

    for (zorder) |wi| {
        if (windows[wi].visible) drawWindow(wi);
    }

    drawDock();
    drawBar();
    drawCursor();

    screen.blit(0, 0, &back);
}

fn drawBar() void {
    back.rect(0, 0, back.w, BAR_H, COL_BAR);
    back.rect(0, @intCast(BAR_H - 1), back.w, 1, COL_DOCK_EDGE);
    back.rect(10, 9, 4, 12, COL_BAR_ACCENT); // little logo tick
    back.text(20, 11, "Cedar OS", COL_BAR_TEXT, null);
    const t = timer.now();
    const hz = timer.tickHz();
    const s = std.fmt.bufPrint(&fmt_buf, "up {d}:{d:0>2}  {d} cpu  {d} MiB free", .{
        t / hz / 60, (t / hz) % 60, smp.onlineCount(), mem.freeMiB(),
    }) catch "";
    back.text(@intCast(back.w - 10 - s.len * 8), 11, s, COL_BAR_TEXT, null);
}

fn drawWindow(wi: usize) void {
    const w = &windows[wi];
    const ow = w.outerW();
    const oh = w.outerH();
    const active = wi == focused();

    // Drop shadow.
    back.rect(w.x + SHADOW, w.y + SHADOW, ow, oh, COL_SHADOW);

    back.rect(w.x, w.y, ow, oh, COL_CHROME);
    back.rect(w.x + 1, w.y + 1, ow - 2, TITLE_H, if (active) COL_TITLE_FOCUS else COL_TITLE_BLUR);
    back.text(w.x + 10, w.y + 8, w.title, if (active) COL_TITLE_TEXT else COL_TITLE_TEXT_BLUR, null);

    // Close button at the right of the title bar.
    const cbx = w.x + @as(i32, @intCast(ow - TITLE_H));
    back.rect(cbx, w.y + 1, TITLE_H, TITLE_H - 1, if (active) COL_WCLOSE else COL_TITLE_BLUR);
    back.text(cbx + 8, w.y + 8, "x", if (active) 0xffffff else COL_TITLE_TEXT_BLUR, null);

    const cy = w.y + @as(i32, @intCast(TITLE_H + BORDER)) - 1;
    if (wi == CONSOLE_WIN) {
        const daif = log.acquireConsole();
        defer log.releaseConsole(daif);
        back.blit(w.x + BORDER, cy, &w.surf);
    } else {
        back.blit(w.x + BORDER, cy, &w.surf);
    }
    back.frame(w.x, w.y, ow, oh, if (active) COL_FRAME_FOCUS else COL_FRAME_BLUR);
}

fn drawDock() void {
    const dy: i32 = @intCast(back.h - DOCK_H);
    back.rect(0, dy, back.w, DOCK_H, COL_DOCK);
    back.rect(0, dy, back.w, 1, COL_DOCK_EDGE);
    const foc = focused();
    var wi: usize = 0;
    while (wi < NWIN) : (wi += 1) {
        const w = &windows[wi];
        const bx: i32 = @intCast(MARGIN + wi * (DOCK_BTN_W + DOCK_BTN_GAP));
        const col = if (!w.visible) COL_DOCK_BTN_OFF else if (wi == foc) COL_DOCK_BTN_HI else COL_DOCK_BTN;
        back.rect(bx, dy + 6, DOCK_BTN_W, DOCK_H - 12, col);
        // A running-indicator pip on the left of each button.
        back.rect(bx + 6, dy + @as(i32, @intCast(DOCK_H / 2)) - 2, 4, 4, if (w.visible) COL_BAR_ACCENT else COL_TEXT_DIM);
        const tc = if (w.visible) COL_TITLE_TEXT else COL_TEXT_DIM;
        back.text(bx + 18, dy + @as(i32, @intCast(DOCK_H / 2)) - 4, w.title, tc, null);
    }
}

fn drawSysmon() void {
    const s = &windows[1].surf;
    s.fill(COL_PANEL_BG);
    var buf: [64]u8 = undefined;
    const hz = timer.tickHz();
    var y: i32 = 12;
    const rows = [_]struct { k: []const u8, v: u64 }{
        .{ .k = "uptime  ", .v = timer.now() / hz },
        .{ .k = "free    ", .v = mem.freeMiB() },
        .{ .k = "total   ", .v = mem.totalMiB() },
        .{ .k = "cpus    ", .v = smp.onlineCount() },
        .{ .k = "ticks   ", .v = timer.now() },
    };
    for (rows) |r| {
        s.text(12, y, r.k, COL_TEXT_DIM, null);
        const v = std.fmt.bufPrint(&buf, "{d}", .{r.v}) catch "";
        s.text(12 + 8 * 8, y, v, COL_TEXT, null);
        y += 18;
    }
}

fn drawAbout() void {
    const s = &windows[2].surf;
    s.fill(COL_PANEL_BG);
    s.text(12, 12, "Cedar OS 0.1 (aarch64)", COL_TEXT, null);
    s.text(12, 32, "no bootloader, no mercy", COL_TEXT_DIM, null);
    s.text(12, 58, "drag titles to move windows", COL_TEXT_DIM, null);
    s.text(12, 74, "x closes a window", COL_TEXT_DIM, null);
    s.text(12, 90, "the dock reopens it", COL_TEXT_DIM, null);
}

// A simple 12x12 arrow, white with a dark outline.
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
            back.rect(cx + @as(i32, @intCast(rx)) + 1, cy + @as(i32, @intCast(ry)) + 1, 1, 1, 0x0a140e);
            back.rect(cx + @as(i32, @intCast(rx)), cy + @as(i32, @intCast(ry)), 1, 1, 0xffffff);
        }
    }
}
