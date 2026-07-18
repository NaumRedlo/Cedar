// Software drawing primitives over 32-bpp linear surfaces: the screen,
// the back buffer, and window content buffers all look the same.

const std = @import("std");
const font = @import("font8x8.zig");
const console = @import("console.zig");

pub const Surface = struct {
    px: [*]u32,
    w: u32,
    h: u32,
    stride: u32, // in pixels

    pub fn fromConsoleFb(f: console.Framebuffer) Surface {
        return .{
            .px = @alignCast(@ptrCast(f.address)),
            .w = @intCast(f.width),
            .h = @intCast(f.height),
            .stride = @intCast(f.pitch / 4),
        };
    }

    pub fn fill(self: *const Surface, color: u32) void {
        for (0..self.h) |y| {
            const row = self.px + y * self.stride;
            @memset(row[0..self.w], color);
        }
    }

    // Filled rectangle, clipped to the surface.
    pub fn rect(self: *const Surface, x: i32, y: i32, w: u32, h: u32, color: u32) void {
        const x0: u32 = @intCast(@max(x, 0));
        const y0: u32 = @intCast(@max(y, 0));
        const x1: u32 = @intCast(std.math.clamp(x + @as(i32, @intCast(w)), 0, @as(i32, @intCast(self.w))));
        const y1: u32 = @intCast(std.math.clamp(y + @as(i32, @intCast(h)), 0, @as(i32, @intCast(self.h))));
        if (x0 >= x1 or y0 >= y1) return;
        for (y0..y1) |yy| {
            const row = self.px + yy * self.stride;
            @memset(row[x0..x1], color);
        }
    }

    // 1-pixel outline.
    pub fn frame(self: *const Surface, x: i32, y: i32, w: u32, h: u32, color: u32) void {
        self.rect(x, y, w, 1, color);
        self.rect(x, y + @as(i32, @intCast(h)) - 1, w, 1, color);
        self.rect(x, y, 1, h, color);
        self.rect(x + @as(i32, @intCast(w)) - 1, y, 1, h, color);
    }

    // 8x8 font text at 1x scale; bg null = transparent.
    pub fn text(self: *const Surface, x: i32, y: i32, s: []const u8, fg: u32, bg: ?u32) void {
        var cx = x;
        for (s) |c| {
            self.glyph(cx, y, if (c < 0x80) c else '?', fg, bg);
            cx += 8;
        }
    }

    fn glyph(self: *const Surface, x: i32, y: i32, c: u8, fg: u32, bg: ?u32) void {
        const g = &font.basic[c];
        for (0..8) |gy| {
            const py = y + @as(i32, @intCast(gy));
            if (py < 0 or py >= self.h) continue;
            const bits = g[gy];
            const row = self.px + @as(u32, @intCast(py)) * self.stride;
            for (0..8) |gx| {
                const px = x + @as(i32, @intCast(gx));
                if (px < 0 or px >= self.w) continue;
                if ((bits >> @intCast(gx)) & 1 != 0) {
                    row[@intCast(px)] = fg;
                } else if (bg) |b| {
                    row[@intCast(px)] = b;
                }
            }
        }
    }

    // Copy `src` onto self at (dx, dy), clipped.
    pub fn blit(self: *const Surface, dx: i32, dy: i32, src: *const Surface) void {
        const x0: i32 = @max(dx, 0);
        const y0: i32 = @max(dy, 0);
        const x1: i32 = @min(dx + @as(i32, @intCast(src.w)), @as(i32, @intCast(self.w)));
        const y1: i32 = @min(dy + @as(i32, @intCast(src.h)), @as(i32, @intCast(self.h)));
        if (x0 >= x1 or y0 >= y1) return;
        const cols: u32 = @intCast(x1 - x0);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            const sy: u32 = @intCast(yy - dy);
            const sx: u32 = @intCast(x0 - dx);
            const drow = self.px + @as(u32, @intCast(yy)) * self.stride + @as(u32, @intCast(x0));
            const srow = src.px + sy * src.stride + sx;
            @memcpy(drow[0..cols], srow[0..cols]);
        }
    }
};
