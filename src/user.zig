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

// Fixed user layout (all inside L1[0], the low 1 GiB of the VA space).
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

const CODE_FLAGS = VALID_PAGE | AF | SH_INNER | ATTR_NORMAL | AP_EL0_RO | PXN;
const STACK_FLAGS = VALID_PAGE | AF | SH_INNER | ATTR_NORMAL | AP_EL0_RW | PXN | UXN;

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
            level = table(level[i] & 0x0000_ffff_ffff_f000);
        }
        level[idx[2]] = phys | flags;
        return true;
    }
};

pub const LoadError = error{ NoMemory, TooBig };

pub const Image = struct {
    ttbr0: u64,
    entry: u64,
    sp: u64,
    argc: u64,
    argv: u64, // user VA of the pointer array
};

// Build a fresh address space: copy `code` to CODE_VA, set up a stack,
// and place the argv block (pointer array + NUL-terminated strings) at
// the very top of the stack, System V style. x0/x1 for the entry come
// back as argc/argv.
pub fn load(code: []const u8, args: []const []const u8) LoadError!Image {
    const code_pages = (code.len + mem.PAGE_SIZE - 1) / mem.PAGE_SIZE;

    var as = AddressSpace{ .root = zeroTable() orelse return error.NoMemory };

    // Code: fresh frames, copied through the direct map, mapped RO+X.
    for (0..code_pages) |p| {
        const frame = mem.frames.allocContiguous(1) orelse return error.NoMemory;
        const dst = @as([*]u8, @ptrFromInt(mmu.p2v(frame)))[0..mem.PAGE_SIZE];
        const off = p * mem.PAGE_SIZE;
        const n = @min(mem.PAGE_SIZE, code.len - off);
        @memcpy(dst[0..n], code[off .. off + n]);
        if (n < mem.PAGE_SIZE) @memset(dst[n..], 0);
        if (!as.mapPage(CODE_VA + off, frame, CODE_FLAGS)) return error.NoMemory;
    }

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
        .entry = CODE_VA,
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
