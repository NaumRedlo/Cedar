// Userspace address spaces and process loading.
//
// EL0 code runs through TTBR0 with 4 KiB pages (a 3-level walk under the
// 39-bit VA: L1 → L2 → L3). Each process gets its own TTBR0 table; a
// shared empty "kernel-low" table is loaded whenever a pure kernel
// thread runs, so a null dereference in the kernel still faults even
// after userspace exists. TTBR0 walks, disabled by boot.S via EPD0, are
// re-enabled here once a valid low table is installed.

const std = @import("std");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const sched = @import("sched.zig");
const elf = @import("elf.zig");

// Fixed user layout (all inside L1[0], the low 1 GiB of the VA space).
// ELF segments load at their own vaddrs (our programs link at CODE_VA);
// the stack sits at the top of the low region. Pointers a process is
// allowed to hand the kernel must fall in [CODE_VA, STACK_TOP).
pub const CODE_VA: u64 = 0x1000_0000;
pub const STACK_TOP: u64 = 0x2000_0000;
pub const STACK_PAGES: usize = 4;

// L3 page descriptor bits.
const VALID_PAGE: u64 = 0b11;
const AF: u64 = 1 << 10;
const SH_INNER: u64 = 3 << 8;
const ATTR_NORMAL: u64 = 0 << 2;
const AP_EL0_RO: u64 = 3 << 6;
const AP_EL0_RW: u64 = 1 << 6;
const PXN: u64 = 1 << 53;
const UXN: u64 = 1 << 54;

const STACK_FLAGS = VALID_PAGE | AF | SH_INNER | ATTR_NORMAL | AP_EL0_RW | PXN | UXN;

// Page permissions for an ELF segment. AP only distinguishes RO/RW;
// UXN gates EL0 execution. Kernel execution of user pages is always
// forbidden (PXN).
fn segmentFlags(f: u32) u64 {
    var bits: u64 = VALID_PAGE | AF | SH_INNER | ATTR_NORMAL | PXN;
    bits |= if (f & elf.PF_W != 0) AP_EL0_RW else AP_EL0_RO;
    if (f & elf.PF_X == 0) bits |= UXN;
    return bits;
}

var kernel_low_table: u64 = 0;

fn zeroTable() ?u64 {
    const phys = mem.frames.allocContiguous(1) orelse return null;
    const t = @as([*]volatile u64, @ptrFromInt(mmu.p2v(phys)))[0..512];
    for (t) |*e| e.* = 0;
    return phys;
}

// Install an empty low table and turn TTBR0 walks back on. After this,
// low addresses fault unless a process table maps them.
pub fn init() bool {
    kernel_low_table = zeroTable() orelse return false;
    asm volatile (
        \\msr ttbr0_el1, %[t]
        \\mrs x8, tcr_el1
        \\bic x8, x8, #(1 << 7)
        \\msr tcr_el1, x8
        \\tlbi vmalle1
        \\dsb nsh
        \\isb
        :
        : [t] "r" (kernel_low_table),
        : .{ .x8 = true, .memory = true });
    sched.setKernelLowTable(kernel_low_table);
    return true;
}

// A secondary core adopts the empty kernel-low table as its default
// TTBR0 (walks stay enabled), so null dereferences fault there too
// while it runs kernel threads. Called once per secondary from smp.
pub fn adoptSecondaryCore() void {
    asm volatile (
        \\msr ttbr0_el1, %[t]
        \\tlbi vmalle1
        \\dsb nsh
        \\isb
        :
        : [t] "r" (kernel_low_table),
        : .{ .memory = true });
}

fn indices(va: u64) [3]usize {
    return .{
        @intCast((va >> 30) & 511),
        @intCast((va >> 21) & 511),
        @intCast((va >> 12) & 511),
    };
}

const AddressSpace = struct {
    root: u64, // TTBR0 physical

    fn table(phys: u64) []volatile u64 {
        return @as([*]volatile u64, @ptrFromInt(mmu.p2v(phys)))[0..512];
    }

    // Walk to the L3 entry for `va`, allocating intermediate tables.
    fn mapPage(self: *AddressSpace, va: u64, phys: u64, flags: u64) bool {
        const idx = indices(va);
        var level = table(self.root);
        for (idx[0..2]) |i| {
            if (level[i] & 1 == 0) {
                const next = zeroTable() orelse return false;
                level[i] = next | 0b11; // table descriptor
            }
            level = table(level[i] & ADDR_MASK);
        }
        level[idx[2]] = phys | flags;
        return true;
    }

    // Physical frame already mapped at `va`, if any — so two ELF
    // segments sharing a page reuse the same frame.
    fn frameAt(self: *AddressSpace, va: u64) ?u64 {
        const idx = indices(va);
        var level = table(self.root);
        for (idx[0..2]) |i| {
            if (level[i] & 1 == 0) return null;
            level = table(level[i] & ADDR_MASK);
        }
        const leaf = level[idx[2]];
        if (leaf & 1 == 0) return null;
        return leaf & ADDR_MASK;
    }

    // Map one ELF PT_LOAD segment: page-granular frames, file bytes
    // copied into place, the tail (mem_size > file_size) left zero.
    fn loadSegment(self: *AddressSpace, image: []const u8, seg: elf.Segment) LoadError!void {
        const flags = segmentFlags(seg.flags);
        const page_start = std.mem.alignBackward(u64, seg.vaddr, mem.PAGE_SIZE);
        const page_end = std.mem.alignForward(u64, seg.vaddr + seg.mem_size, mem.PAGE_SIZE);

        var va = page_start;
        while (va < page_end) : (va += mem.PAGE_SIZE) {
            const frame = self.frameAt(va) orelse blk: {
                const f = mem.frames.allocContiguous(1) orelse return error.NoMemory;
                @memset(@as([*]u8, @ptrFromInt(mmu.p2v(f)))[0..mem.PAGE_SIZE], 0);
                if (!self.mapPage(va, f, flags)) return error.NoMemory;
                break :blk f;
            };
            const page_va = mmu.p2v(frame);
            const page = @as([*]u8, @ptrFromInt(page_va))[0..mem.PAGE_SIZE];

            // Copy the portion of the segment's file image on this page.
            const file_lo = @max(va, seg.vaddr);
            const file_hi = @min(va + mem.PAGE_SIZE, seg.vaddr + seg.file_size);
            if (file_lo < file_hi) {
                const src_off = seg.file_off + (file_lo - seg.vaddr);
                const dst_off = file_lo - va;
                const len = file_hi - file_lo;
                if (src_off + len > image.len) return error.TooBig;
                @memcpy(page[dst_off..][0..len], image[@intCast(src_off)..][0..@intCast(len)]);
            }

            // Clean this page (written via the direct map) to the point
            // of unification, so instruction fetch sees the new bytes.
            if (seg.flags & elf.PF_X != 0) cleanDCacheToPoU(page_va, mem.PAGE_SIZE);
        }
    }
};

fn cacheLine() u64 {
    const ctr = asm volatile ("mrs %[out], ctr_el0"
        : [out] "=r" (-> u64),
    );
    // CTR_EL0.DminLine (bits 19:16): log2 of the smallest D-cache line
    // in words. Line size in bytes = 4 << DminLine.
    return @as(u64, 4) << @intCast((ctr >> 16) & 0xf);
}

fn cleanDCacheToPoU(va: u64, len: u64) void {
    const line = cacheLine();
    var p = std.mem.alignBackward(u64, va, line);
    const end = va + len;
    while (p < end) : (p += line) {
        asm volatile ("dc cvau, %[p]"
            :
            : [p] "r" (p),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

// Finish code loading: publish page tables and invalidate every core's
// instruction cache so the fresh code is fetched correctly anywhere.
fn syncInstructionCache() void {
    asm volatile (
        \\dsb ish
        \\ic ialluis
        \\dsb ish
        \\isb
        ::: .{ .memory = true });
}

pub const LoadError = error{ NoMemory, TooBig } || elf.Error;

pub const Image = struct {
    ttbr0: u64,
    entry: u64,
    sp: u64,
    argc: u64,
    argv: u64, // user VA of the pointer array
};

// Build a fresh address space from an ELF64 executable: map its
// PT_LOAD segments with per-segment permissions, set up a stack, and
// place the argv block (pointer array + NUL-terminated strings) at the
// top of the stack, System V style. x0/x1 for the entry are argc/argv.
pub fn load(image: []const u8, args: []const []const u8) LoadError!Image {
    const exe = try elf.Elf.parse(image);

    var as = AddressSpace{ .root = zeroTable() orelse return error.NoMemory };

    var segs = exe.segments();
    while (segs.next()) |seg| {
        // Programs live in the low user window, never over the stack.
        if (seg.vaddr < CODE_VA or seg.vaddr + seg.mem_size > STACK_TOP - STACK_PAGES * mem.PAGE_SIZE) {
            return error.TooBig;
        }
        try as.loadSegment(image, seg);
    }

    // We wrote the program's code as data (through the direct map) but
    // it will be fetched as instructions, possibly on another core.
    // Clean it to the point of unification and invalidate the I-cache
    // inner-shareable so every core fetches the fresh bytes; the dsb
    // also publishes the new page tables to other cores' walkers.
    syncInstructionCache();

    // Stack: zeroed frames mapped RW below STACK_TOP.
    var top_page: [*]u8 = undefined;
    for (0..STACK_PAGES) |p| {
        const frame = mem.frames.allocContiguous(1) orelse return error.NoMemory;
        const page = @as([*]u8, @ptrFromInt(mmu.p2v(frame)))[0..mem.PAGE_SIZE];
        @memset(page, 0);
        const va = STACK_TOP - (p + 1) * mem.PAGE_SIZE;
        if (!as.mapPage(va, frame, STACK_FLAGS)) return error.NoMemory;
        if (p == 0) top_page = page.ptr;
    }

    // argv block: [argv[0..argc], NULL] then the string bytes, written
    // through the direct map before the process ever runs.
    var total: usize = (args.len + 1) * 8;
    for (args) |a| total += a.len + 1;
    total = std.mem.alignForward(usize, total, 16);
    if (total > mem.PAGE_SIZE) return error.TooBig;

    const block_va = STACK_TOP - total;
    const off0 = mem.PAGE_SIZE - total;
    const ptrs = @as([*]align(1) u64, @ptrCast(top_page + off0));
    var str_off = off0 + (args.len + 1) * 8;
    for (args, 0..) |a, i| {
        ptrs[i] = block_va + (str_off - off0);
        @memcpy(top_page[str_off .. str_off + a.len], a);
        top_page[str_off + a.len] = 0;
        str_off += a.len + 1;
    }
    ptrs[args.len] = 0;

    return .{
        .ttbr0 = as.root,
        .entry = exe.entry,
        .sp = block_va,
        .argc = args.len,
        .argv = block_va,
    };
}

const ADDR_MASK: u64 = 0x0000_ffff_ffff_f000;

fn freeLevel(phys: u64, level: u32) void {
    const t = @as([*]volatile u64, @ptrFromInt(mmu.p2v(phys)))[0..512];
    for (t) |entry| {
        if (entry & 1 == 0) continue;
        const next = entry & ADDR_MASK;
        if (level < 3) {
            // L1/L2 valid entries are always table descriptors here.
            freeLevel(next, level + 1);
        } else {
            // L3 leaf: the mapped code/stack frame.
            mem.frames.free(next);
        }
    }
    mem.frames.free(phys);
}

// Return every frame owned by a process address space: its mapped
// pages and all three levels of page table. The table must not be the
// live TTBR0 when this runs (the reaper guarantees it).
pub fn destroy(ttbr0: u64) void {
    freeLevel(ttbr0, 1);
}
