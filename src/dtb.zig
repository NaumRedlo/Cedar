// Minimal read-only parser for the flattened device tree (FDT/DTB) the
// boot environment hands us in x0. All integers in the blob are
// big-endian (devicetree spec v0.4, chapter 5).

const std = @import("std");

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

pub const Error = error{ BadMagic, Truncated, BadStructure };

fn be32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn be64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .big);
}

fn alignUp4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

fn readCstr(bytes: []const u8, off: usize) ?[]const u8 {
    if (off >= bytes.len) return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, off, 0) orelse return null;
    return bytes[off..end];
}

// Property values that are strings carry a trailing NUL; trim it.
pub fn str(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == 0) return value[0 .. value.len - 1];
    return value;
}

pub const Prop = struct { name: []const u8, value: []const u8 };

pub const Event = union(enum) {
    begin_node: []const u8,
    end_node,
    prop: Prop,
    end,
};

pub const Reg = struct { addr: u64, size: u64 };

pub const Dtb = struct {
    raw: []const u8,
    strct: []const u8,
    strings: []const u8,
    version: u32,

    pub fn init(phys: usize) Error!Dtb {
        const p: [*]const u8 = @ptrFromInt(phys);
        if (be32(p[0..8], 0) != FDT_MAGIC) return Error.BadMagic;
        const totalsize = be32(p[0..8], 4);
        if (totalsize < 40) return Error.Truncated;
        const raw = p[0..totalsize];
        const off_struct = be32(raw, 8);
        const off_strings = be32(raw, 12);
        const version = be32(raw, 20);
        const size_strings = be32(raw, 32);
        const size_struct = be32(raw, 36);
        if (off_struct + size_struct > totalsize) return Error.Truncated;
        if (off_strings + size_strings > totalsize) return Error.Truncated;
        return .{
            .raw = raw,
            .strct = raw[off_struct..][0..size_struct],
            .strings = raw[off_strings..][0..size_strings],
            .version = version,
        };
    }

    pub fn iterator(self: *const Dtb) Iterator {
        return .{ .dtb = self };
    }

    // Memory reservation block: (address, size) pairs the kernel must
    // never hand out, terminated by a zero pair.
    pub fn reservations(self: *const Dtb) ReservationIterator {
        return .{ .raw = self.raw, .off = be32(self.raw, 16) };
    }

    // Value of a property that sits directly on the root node.
    pub fn rootProp(self: *const Dtb, name: []const u8) ?[]const u8 {
        var it = self.iterator();
        var depth: u32 = 0;
        while (true) {
            const ev = it.next() catch return null;
            switch (ev) {
                .begin_node => {
                    depth += 1;
                    if (depth > 1) return null; // first child: root props are over
                },
                .prop => |p| if (depth == 1 and std.mem.eql(u8, p.name, name)) return p.value,
                .end_node, .end => return null,
            }
        }
    }

    fn rootCells(self: *const Dtb, name: []const u8, default: u32) u32 {
        const v = self.rootProp(name) orelse return default;
        if (v.len < 4) return default;
        return be32(v, 0);
    }

    fn parseReg(self: *const Dtb, value: []const u8) ?Reg {
        const addr_cells = self.rootCells("#address-cells", 2);
        const size_cells = self.rootCells("#size-cells", 1);
        if (addr_cells > 2 or size_cells > 2) return null;
        const need = (addr_cells + size_cells) * 4;
        if (value.len < need) return null;

        var off: usize = 0;
        var addr: u64 = 0;
        for (0..addr_cells) |_| {
            addr = (addr << 32) | be32(value, off);
            off += 4;
        }
        var size: u64 = 0;
        for (0..size_cells) |_| {
            size = (size << 32) | be32(value, off);
            off += 4;
        }
        return .{ .addr = addr, .size = size };
    }

    // First node at root level whose name starts with the given prefix.
    pub fn findByNodePrefix(self: *const Dtb, prefix: []const u8) ?Reg {
        const value = self.scan(prefix, false) orelse return null;
        return self.parseReg(value);
    }

    // First node whose "compatible" list contains the given string.
    pub fn findByCompatible(self: *const Dtb, compat: []const u8) ?Reg {
        const value = self.scan(compat, true) orelse return null;
        return self.parseReg(value);
    }

    // Same, but fills `out` with consecutive (addr, size) pairs from the
    // node's reg property (e.g. GIC distributor + cpu interface).
    pub fn findRegsByCompatible(self: *const Dtb, compat: []const u8, out: []Reg) usize {
        const value = self.scan(compat, true) orelse return 0;
        const addr_cells = self.rootCells("#address-cells", 2);
        const size_cells = self.rootCells("#size-cells", 1);
        if (addr_cells > 2 or size_cells > 2) return 0;
        const stride = (addr_cells + size_cells) * 4;
        var n: usize = 0;
        while (n < out.len and (n + 1) * stride <= value.len) : (n += 1) {
            out[n] = self.parseReg(value[n * stride ..]) orelse break;
        }
        return n;
    }

    fn scan(self: *const Dtb, needle: []const u8, by_compatible: bool) ?[]const u8 {
        var it = self.iterator();
        var matched = false;
        var reg_value: ?[]const u8 = null;

        while (true) {
            const ev = it.next() catch return null;
            switch (ev) {
                .begin_node => |name| {
                    // Properties always precede subnodes, so the previous
                    // node is fully described once a child (or end) shows up.
                    if (matched) if (reg_value) |rv| return rv;
                    matched = !by_compatible and std.mem.startsWith(u8, name, needle);
                    reg_value = null;
                },
                .end_node => {
                    if (matched) if (reg_value) |rv| return rv;
                    matched = false;
                    reg_value = null;
                },
                .prop => |p| {
                    if (std.mem.eql(u8, p.name, "reg")) reg_value = p.value;
                    if (by_compatible and std.mem.eql(u8, p.name, "compatible")) {
                        var rest = p.value;
                        while (std.mem.indexOfScalar(u8, rest, 0)) |nul| {
                            if (std.mem.eql(u8, rest[0..nul], needle)) matched = true;
                            rest = rest[nul + 1 ..];
                        }
                    }
                },
                .end => return null,
            }
        }
    }
};

pub const ReservationIterator = struct {
    raw: []const u8,
    off: usize,

    pub fn next(it: *ReservationIterator) ?Reg {
        if (it.off + 16 > it.raw.len) return null;
        const addr = be64(it.raw, it.off);
        const size = be64(it.raw, it.off + 8);
        it.off += 16;
        if (addr == 0 and size == 0) return null;
        return .{ .addr = addr, .size = size };
    }
};

pub const Iterator = struct {
    dtb: *const Dtb,
    off: usize = 0,

    pub fn next(it: *Iterator) Error!Event {
        const s = it.dtb.strct;
        while (true) {
            if (it.off + 4 > s.len) return Error.Truncated;
            const token = be32(s, it.off);
            it.off += 4;
            switch (token) {
                FDT_NOP => continue,
                FDT_BEGIN_NODE => {
                    const name = readCstr(s, it.off) orelse return Error.Truncated;
                    it.off = alignUp4(it.off + name.len + 1);
                    return .{ .begin_node = name };
                },
                FDT_END_NODE => return .end_node,
                FDT_PROP => {
                    if (it.off + 8 > s.len) return Error.Truncated;
                    const len = be32(s, it.off);
                    const nameoff = be32(s, it.off + 4);
                    it.off += 8;
                    if (it.off + len > s.len) return Error.Truncated;
                    const value = s[it.off..][0..len];
                    it.off = alignUp4(it.off + len);
                    const name = readCstr(it.dtb.strings, nameoff) orelse return Error.Truncated;
                    return .{ .prop = .{ .name = name, .value = value } };
                },
                FDT_END => return .end,
                else => return Error.BadStructure,
            }
        }
    }
};

const testing = std.testing;

fn fixture() Dtb {
    const blob align(8) = @embedFile("testdata/virt-fixture.dtb").*;
    const S = struct {
        var stored: [blob.len]u8 align(8) = undefined;
    };
    S.stored = blob;
    return Dtb.init(@intFromPtr(&S.stored)) catch unreachable;
}

test "header parses" {
    const dt = fixture();
    try testing.expect(dt.version >= 17);
    try testing.expect(dt.raw.len > 0);
}

test "root model property" {
    const dt = fixture();
    const model = dt.rootProp("model") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("linux,dummy-virt", str(model));
}

test "memory node reg" {
    const dt = fixture();
    const mem = dt.findByNodePrefix("memory") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x40000000), mem.addr);
    try testing.expectEqual(@as(u64, 0x80000000), mem.size);
}

test "find pl011 by compatible" {
    const dt = fixture();
    const uart = dt.findByCompatible("arm,pl011") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x9000000), uart.addr);
    try testing.expectEqual(@as(u64, 0x1000), uart.size);
}

test "compatible miss returns null" {
    const dt = fixture();
    try testing.expect(dt.findByCompatible("brcm,bcm2711") == null);
    try testing.expect(dt.findByNodePrefix("nonexistent") == null);
}

test "multiple reg pairs (gic dist + cpu iface)" {
    const dt = fixture();
    var regs: [4]Reg = undefined;
    const n = dt.findRegsByCompatible("arm,cortex-a15-gic", &regs);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 0x8000000), regs[0].addr);
    try testing.expectEqual(@as(u64, 0x8010000), regs[1].addr);
    try testing.expectEqual(@as(u64, 0x10000), regs[1].size);
}

test "second compatible entry in list matches" {
    const dt = fixture();
    const node = dt.findByCompatible("arm,primecell") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x9000000), node.addr);
}

test "memory reservation block" {
    const dt = fixture();
    var it = dt.reservations();
    const r = it.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x47000000), r.addr);
    try testing.expectEqual(@as(u64, 0x10000), r.size);
    try testing.expect(it.next() == null);
}

test "bad magic rejected" {
    var junk align(8) = [_]u8{0} ** 64;
    try testing.expectError(Error.BadMagic, Dtb.init(@intFromPtr(&junk)));
}
