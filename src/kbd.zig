// virtio-input keyboard: claims the input device whose name says
// "keyboard", translates evdev key events through a US keymap and
// feeds the shared input ring — the shell can't tell typing in the
// QEMU window from typing in the terminal.

const std = @import("std");
const vinput = @import("virtio_input.zig");
const input = @import("input.zig");

const EV_KEY = 1;
const KEY_LSHIFT = 42;
const KEY_RSHIFT = 54;

var dev = vinput.Device{};
var shift = false;

pub var present = false;
pub var intid: u32 = 0xffff_ffff;

pub fn tryClaim(base_virt: u64, irq: u32) bool {
    if (present) return false;
    var name_buf: [64]u8 = undefined;
    const name = vinput.probeName(base_virt, &name_buf) orelse return false;
    if (std.ascii.indexOfIgnoreCase(name, "keyboard") == null) return false;
    if (!dev.init(base_virt, &handleEvent)) return false;
    intid = irq;
    present = true;
    return true;
}

pub fn onIrq() void {
    dev.onIrq();
}

// US layout, evdev keycodes 0..63.
const plain = [64]u8{
    0, 0, '1', '2', '3', '4', '5', '6', '7', '8', // 0-9
    '9', '0', '-', '=', 0x7f, '\t', 'q', 'w', 'e', 'r', // 10-19
    't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\r', 0, // 20-29
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 30-39
    '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', // 40-49
    'm', ',', '.', '/', 0, 0, 0, ' ', 0, 0, // 50-59
    0, 0, 0, 0, // 60-63
};

const shifted = [64]u8{
    0, 0, '!', '@', '#', '$', '%', '^', '&', '*', // 0-9
    '(', ')', '_', '+', 0x7f, '\t', 'Q', 'W', 'E', 'R', // 10-19
    'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\r', 0, // 20-29
    'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', // 30-39
    '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', // 40-49
    'M', '<', '>', '?', 0, 0, 0, ' ', 0, 0, // 50-59
    0, 0, 0, 0, // 60-63
};

fn handleEvent(ev: vinput.Event) void {
    if (ev.kind != EV_KEY) return;
    if (ev.code == KEY_LSHIFT or ev.code == KEY_RSHIFT) {
        shift = ev.value != 0;
        return;
    }
    if (ev.value == 0) return; // release
    if (ev.code >= plain.len) return;
    const c = if (shift) shifted[ev.code] else plain[ev.code];
    if (c != 0) input.pushByte(c);
}
