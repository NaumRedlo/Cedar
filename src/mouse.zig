// virtio-tablet pointer: absolute coordinates (0..32767 per axis)
// scaled to the screen, plus the left button. State is polled by the
// window manager each frame; the IRQ just keeps it fresh.

const std = @import("std");
const vinput = @import("virtio_input.zig");

const EV_KEY = 1;
const EV_ABS = 3;
const ABS_X = 0;
const ABS_Y = 1;
const BTN_LEFT = 0x110;
const AXIS_MAX: u64 = 32767;

var dev = vinput.Device{};
var screen_w: u32 = 1024;
var screen_h: u32 = 768;

pub var present = false;
pub var intid: u32 = 0xffff_ffff;

// Written from IRQ context, read (volatile) by the WM loop.
var cur_x: u32 = 512;
var cur_y: u32 = 384;
var cur_left = false;

pub fn tryClaim(base_virt: u64, irq: u32) bool {
    if (present) return false;
    var name_buf: [64]u8 = undefined;
    const name = vinput.probeName(base_virt, &name_buf) orelse return false;
    if (std.ascii.indexOfIgnoreCase(name, "tablet") == null and
        std.ascii.indexOfIgnoreCase(name, "mouse") == null) return false;
    if (!dev.init(base_virt, &handleEvent)) return false;
    intid = irq;
    present = true;
    return true;
}

pub fn setScreen(w: u32, h: u32) void {
    screen_w = w;
    screen_h = h;
}

pub fn onIrq() void {
    dev.onIrq();
}

pub const State = struct { x: u32, y: u32, left: bool };

pub fn state() State {
    return .{
        .x = @as(*volatile u32, &cur_x).*,
        .y = @as(*volatile u32, &cur_y).*,
        .left = @as(*volatile bool, &cur_left).*,
    };
}

fn handleEvent(ev: vinput.Event) void {
    switch (ev.kind) {
        EV_ABS => switch (ev.code) {
            // Volatile stores to match the volatile reads in state():
            // the WM polls these from another core, so keep the compiler
            // from sinking or eliding the update.
            ABS_X => @as(*volatile u32, &cur_x).* = @intCast(@as(u64, ev.value) * (screen_w - 1) / AXIS_MAX),
            ABS_Y => @as(*volatile u32, &cur_y).* = @intCast(@as(u64, ev.value) * (screen_h - 1) / AXIS_MAX),
            else => {},
        },
        EV_KEY => {
            if (ev.code == BTN_LEFT) @as(*volatile bool, &cur_left).* = ev.value != 0;
        },
        else => {},
    }
}
