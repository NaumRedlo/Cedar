// Minimal ELF64 loader support: just enough to read a static,
// non-relocatable aarch64 executable's program headers. Pure logic
// over a byte slice — host-unit-tested. The kernel maps the segments.

const std = @import("std");

pub const Error = error{
    TooSmall,
    NotElf,
    NotElf64,
    NotLittleEndian,
    NotExecutable,
    WrongArch,
    BadProgramHeaders,
};

// e_ident indices / values.
const EI_CLASS = 4;
const EI_DATA = 5;
const ELFCLASS64 = 2;
const ELFDATA2LSB = 1;
const ET_EXEC = 2;
const EM_AARCH64 = 183;
const PT_LOAD = 1;

// Segment permission flags (p_flags).
pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

pub const Segment = struct {
    vaddr: u64,
    file_off: u64,
    file_size: u64,
    mem_size: u64, // >= file_size; the tail is zero-filled (.bss)
    flags: u32,
};

pub const Elf = struct {
    data: []const u8,
    entry: u64,
    ph_off: u64,
    ph_ent_size: u16,
    ph_count: u16,

    pub fn parse(data: []const u8) Error!Elf {
        if (data.len < 64) return Error.TooSmall;
        if (!std.mem.eql(u8, data[0..4], "\x7fELF")) return Error.NotElf;
        if (data[EI_CLASS] != ELFCLASS64) return Error.NotElf64;
        if (data[EI_DATA] != ELFDATA2LSB) return Error.NotLittleEndian;

        const e_type = rd(u16, data, 16);
        if (e_type != ET_EXEC) return Error.NotExecutable;
        if (rd(u16, data, 18) != EM_AARCH64) return Error.WrongArch;

        const ph_off = rd(u64, data, 32);
        const ph_ent_size = rd(u16, data, 54);
        const ph_count = rd(u16, data, 56);
        if (ph_ent_size < 56) return Error.BadProgramHeaders;
        if (ph_off + @as(u64, ph_count) * ph_ent_size > data.len) return Error.BadProgramHeaders;

        return .{
            .data = data,
            .entry = rd(u64, data, 24),
            .ph_off = ph_off,
            .ph_ent_size = ph_ent_size,
            .ph_count = ph_count,
        };
    }

    pub const SegmentIterator = struct {
        elf: *const Elf,
        i: u16 = 0,

        pub fn next(self: *SegmentIterator) ?Segment {
            while (self.i < self.elf.ph_count) {
                const base = self.elf.ph_off + @as(u64, self.i) * self.elf.ph_ent_size;
                self.i += 1;
                const d = self.elf.data;
                if (rd(u32, d, base) != PT_LOAD) continue;
                return .{
                    .flags = rd(u32, d, base + 4),
                    .file_off = rd(u64, d, base + 8),
                    .vaddr = rd(u64, d, base + 16),
                    .file_size = rd(u64, d, base + 32),
                    .mem_size = rd(u64, d, base + 40),
                };
            }
            return null;
        }
    };

    pub fn segments(self: *const Elf) SegmentIterator {
        return .{ .elf = self };
    }
};

fn rd(comptime T: type, data: []const u8, off: u64) T {
    const o: usize = @intCast(off);
    return std.mem.readInt(T, data[o..][0..@sizeOf(T)], .little);
}

const testing = std.testing;

// A hand-built minimal ELF64: header + one PT_LOAD segment.
fn buildFixture(buf: []u8, e_type: u16, machine: u16) usize {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[EI_CLASS] = ELFCLASS64;
    buf[EI_DATA] = ELFDATA2LSB;
    std.mem.writeInt(u16, buf[16..18], e_type, .little);
    std.mem.writeInt(u16, buf[18..20], machine, .little);
    std.mem.writeInt(u64, buf[24..32], 0x10000000, .little); // e_entry
    std.mem.writeInt(u64, buf[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, buf[56..58], 1, .little); // e_phnum

    const ph = 64;
    std.mem.writeInt(u32, buf[ph .. ph + 4][0..4], PT_LOAD, .little);
    std.mem.writeInt(u32, buf[ph + 4 .. ph + 8][0..4], PF_R | PF_X, .little);
    std.mem.writeInt(u64, buf[ph + 8 .. ph + 16][0..8], 0x200, .little); // p_offset
    std.mem.writeInt(u64, buf[ph + 16 .. ph + 24][0..8], 0x10000000, .little); // p_vaddr
    std.mem.writeInt(u64, buf[ph + 32 .. ph + 40][0..8], 0x40, .little); // p_filesz
    std.mem.writeInt(u64, buf[ph + 40 .. ph + 48][0..8], 0x1000, .little); // p_memsz
    return 0x240;
}

test "parse a valid aarch64 executable" {
    var buf: [0x300]u8 = undefined;
    const n = buildFixture(&buf, ET_EXEC, EM_AARCH64);
    const elf = try Elf.parse(buf[0..n]);
    try testing.expectEqual(@as(u64, 0x10000000), elf.entry);

    var it = elf.segments();
    const seg = it.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x10000000), seg.vaddr);
    try testing.expectEqual(@as(u64, 0x40), seg.file_size);
    try testing.expectEqual(@as(u64, 0x1000), seg.mem_size);
    try testing.expectEqual(PF_R | PF_X, seg.flags);
    try testing.expect(it.next() == null);
}

test "reject non-elf and wrong class/type/arch" {
    var buf: [0x300]u8 = undefined;
    _ = buildFixture(&buf, ET_EXEC, EM_AARCH64);

    var junk = [_]u8{0} ** 64;
    try testing.expectError(Error.NotElf, Elf.parse(&junk));

    var b2: [0x300]u8 = undefined;
    _ = buildFixture(&b2, ET_EXEC, EM_AARCH64);
    b2[EI_CLASS] = 1; // 32-bit
    try testing.expectError(Error.NotElf64, Elf.parse(b2[0..0x240]));

    var b3: [0x300]u8 = undefined;
    _ = buildFixture(&b3, 1, EM_AARCH64); // ET_REL
    try testing.expectError(Error.NotExecutable, Elf.parse(b3[0..0x240]));

    var b4: [0x300]u8 = undefined;
    _ = buildFixture(&b4, ET_EXEC, 62); // x86-64
    try testing.expectError(Error.WrongArch, Elf.parse(b4[0..0x240]));
}

test "reject truncated program headers" {
    var buf: [0x300]u8 = undefined;
    _ = buildFixture(&buf, ET_EXEC, EM_AARCH64);
    // Claim 100 program headers that don't fit.
    std.mem.writeInt(u16, buf[56..58], 100, .little);
    try testing.expectError(Error.BadProgramHeaders, Elf.parse(buf[0..0x240]));
}
