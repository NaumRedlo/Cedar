// Text console rendered onto a linear 32-bpp framebuffer with an 8x8
// bitmap font. Wraps at the right edge and scrolls at the bottom.
//
// Currently dormant: with the move to direct kernel-image boot there is
// no framebuffer provider yet. It returns once Cedar drives the display
// itself (fw_cfg/ramfb on QEMU virt, mailbox on Raspberry Pi).

const font = @import("font8x8.zig");

pub const Framebuffer = struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
};

const GLYPH_W = 8;
const GLYPH_H = 8;
const SCALE = 2;
const CELL_W = GLYPH_W * SCALE;
const CELL_H = GLYPH_H * SCALE;

const BG: u32 = 0x0d1a12; // dark cedar green
const FG: u32 = 0xd7e4d0; // pale green-white

var fb: ?Framebuffer = null;
var words_per_row: u64 = 0;
var cols: u64 = 0;
var rows: u64 = 0;
var cur_col: u64 = 0;
var cur_row: u64 = 0;

pub fn init(desc: Framebuffer) void {
    fb = desc;
    words_per_row = desc.pitch / 4;
    cols = desc.width / CELL_W;
    rows = desc.height / CELL_H;
    clear();
}

pub fn ready() bool {
    return fb != null;
}

fn pixels() [*]volatile u32 {
    return @alignCast(@ptrCast(fb.?.address));
}

pub fn clear() void {
    const f = fb orelse return;
    const px = pixels();
    for (0..f.height) |y| {
        const row = px + y * words_per_row;
        for (0..f.width) |x| row[x] = BG;
    }
    cur_col = 0;
    cur_row = 0;
}

fn drawGlyph(c: u8, col: u64, row: u64) void {
    const glyph = &font.basic[if (c < 0x80) c else '?'];
    const px = pixels();
    const x0 = col * CELL_W;
    const y0 = row * CELL_H;
    for (0..GLYPH_H) |gy| {
        const bits = glyph[gy];
        for (0..GLYPH_W) |gx| {
            const color: u32 = if ((bits >> @intCast(gx)) & 1 != 0) FG else BG;
            for (0..SCALE) |sy| {
                const line = px + (y0 + gy * SCALE + sy) * words_per_row;
                for (0..SCALE) |sx| {
                    line[x0 + gx * SCALE + sx] = color;
                }
            }
        }
    }
}

fn newline() void {
    cur_col = 0;
    cur_row += 1;
    if (cur_row == rows) {
        scroll();
        cur_row = rows - 1;
    }
}

fn scroll() void {
    const f = fb.?;
    const px = pixels();
    const shift = CELL_H * words_per_row;
    const kept_lines = (rows - 1) * CELL_H;
    for (0..kept_lines) |y| {
        const dst = px + y * words_per_row;
        const src = dst + shift;
        for (0..f.width) |x| dst[x] = src[x];
    }
    for (kept_lines..rows * CELL_H) |y| {
        const line = px + y * words_per_row;
        for (0..f.width) |x| line[x] = BG;
    }
}

pub fn putChar(c: u8) void {
    if (fb == null) return;
    switch (c) {
        '\n' => newline(),
        '\r' => cur_col = 0,
        0x08 => { // backspace: erase the previous cell
            if (cur_col > 0) {
                cur_col -= 1;
                drawGlyph(' ', cur_col, cur_row);
            }
        },
        else => {
            drawGlyph(c, cur_col, cur_row);
            cur_col += 1;
            if (cur_col == cols) newline();
        },
    }
}

pub fn write(s: []const u8) void {
    for (s) |c| putChar(c);
}
