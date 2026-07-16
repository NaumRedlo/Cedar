// First kernel heap: a fixed region of contiguous frames from the PMM,
// served through std.mem.Allocator via FixedBufferAllocator. A proper
// growable kernel allocator comes later; this already makes std
// containers usable inside Cedar.

const std = @import("std");
const mem = @import("mem.zig");

var fba: std.heap.FixedBufferAllocator = undefined;
var ready = false;

pub fn init(pages: usize) bool {
    const addr = mem.frames.allocContiguous(pages) orelse return false;
    const buf = @as([*]u8, @ptrFromInt(addr))[0 .. pages * mem.PAGE_SIZE];
    fba = std.heap.FixedBufferAllocator.init(buf);
    ready = true;
    return true;
}

pub fn allocator() std.mem.Allocator {
    std.debug.assert(ready);
    return fba.allocator();
}
