// Cedar FS persistence: the whole tree as a snapshot on the virtio
// disk. Payload streams through 512-byte sectors starting at sector 1;
// the header (magic + length) is written to sector 0 LAST, so a crash
// mid-save leaves the previous snapshot's header intact rather than a
// torn one.

const std = @import("std");
const virtio = @import("virtio.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const MAGIC = "CEDARFS1";

const SectorWriter = struct {
    sector: u64 = 1,
    buf: [virtio.SECTOR]u8 = undefined,
    fill: usize = 0,
    total: u64 = 0,

    pub fn writeAll(self: *SectorWriter, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, self.buf.len - self.fill);
            @memcpy(self.buf[self.fill..][0..n], rest[0..n]);
            self.fill += n;
            self.total += n;
            rest = rest[n..];
            if (self.fill == self.buf.len) try self.flush();
        }
    }

    pub fn flush(self: *SectorWriter) !void {
        if (self.fill == 0) return;
        @memset(self.buf[self.fill..], 0);
        try virtio.writeSector(self.sector, &self.buf);
        self.sector += 1;
        self.fill = 0;
    }
};

const SectorReader = struct {
    sector: u64 = 1,
    buf: [virtio.SECTOR]u8 = undefined,
    off: usize = virtio.SECTOR, // empty until the first fill
    remaining: u64,

    pub fn readAll(self: *SectorReader, out: []u8) !void {
        if (out.len > self.remaining) return error.EndOfStream;
        self.remaining -= out.len;
        var rest = out;
        while (rest.len > 0) {
            if (self.off == self.buf.len) {
                try virtio.readSector(self.sector, &self.buf);
                self.sector += 1;
                self.off = 0;
            }
            const n = @min(rest.len, self.buf.len - self.off);
            @memcpy(rest[0..n], self.buf[self.off..][0..n]);
            self.off += n;
            rest = rest[n..];
        }
    }
};

pub const SnapError = error{ NoDisk, NoSnapshot, Corrupt } || virtio.IoError;

pub fn save() !u64 {
    if (!virtio.present) return SnapError.NoDisk;

    var w = SectorWriter{};
    try fs.global.serialize(&w);
    try w.flush();

    // Commit point: header goes in only after the payload is on disk.
    var header: [virtio.SECTOR]u8 = @splat(0);
    @memcpy(header[0..8], MAGIC);
    std.mem.writeInt(u64, header[8..16], w.total, .little);
    try virtio.writeSector(0, &header);
    return w.total;
}

// Restore into a fresh Fs; the caller decides what to do with it.
pub fn load(alloc: std.mem.Allocator) !fs.Fs {
    if (!virtio.present) return SnapError.NoDisk;

    var header: [virtio.SECTOR]u8 = undefined;
    try virtio.readSector(0, &header);
    if (!std.mem.eql(u8, header[0..8], MAGIC)) return SnapError.NoSnapshot;
    const total = std.mem.readInt(u64, header[8..16], .little);
    if (total == 0 or total > virtio.capacity_sectors * virtio.SECTOR) return SnapError.Corrupt;

    var r = SectorReader{ .remaining = total };
    return fs.Fs.deserialize(alloc, &r);
}
