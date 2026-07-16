// MMU stage 1: identity mapping with 1 GiB level-1 blocks.
//
// 39-bit VA space (T0SZ=25, 4 KiB granule) needs only a single L1 table
// of 512 entries, each covering 1 GiB. Everything below RAM is mapped as
// Device-nGnRnE (UART, GIC, flash); RAM is Normal write-back cacheable.
// Virtual addresses equal physical ones for now — the higher-half kernel
// comes in a later stage, this one buys us translation, permissions,
// caches and (on ARM, MMU-gated) atomics.

const log = @import("log.zig");

var l1_table: [512]u64 align(4096) = [_]u64{0} ** 512;

const GIB: u64 = 1 << 30;

// Descriptor bits (block entry, level 1).
const VALID: u64 = 1 << 0; // bit 1 stays 0: block, not table
const AF: u64 = 1 << 10; // access flag — faults if unset
const ATTR_NORMAL: u64 = 0 << 2; // MAIR index 0
const ATTR_DEVICE: u64 = 1 << 2; // MAIR index 1
const SH_INNER: u64 = 3 << 8;
const PXN: u64 = 1 << 53;
const UXN: u64 = 1 << 54;

// MAIR: index 0 = Normal WB write-allocate, index 1 = Device-nGnRnE.
const MAIR: u64 = 0xff | (0x04 << 8);

// TCR: T0SZ=25 (39-bit VA), 4K granule, WBWA inner-shareable table walks,
// 40-bit IPS, TTBR1 walks disabled until the higher-half stage.
const TCR: u64 = 25 | (1 << 8) | (1 << 10) | (3 << 12) | (2 << 32) | (1 << 23);

fn idx(addr: u64) usize {
    return @intCast((addr >> 30) & 511);
}

pub fn enable(ram_base: u64, ram_size: u64) void {
    var addr: u64 = 0;
    while (addr < ram_base) : (addr += GIB) {
        l1_table[idx(addr)] = addr | VALID | AF | ATTR_DEVICE | PXN | UXN;
    }
    const ram_end = ram_base + ram_size;
    addr = ram_base;
    while (addr < ram_end) : (addr += GIB) {
        l1_table[idx(addr)] = addr | VALID | AF | ATTR_NORMAL | SH_INNER;
    }

    asm volatile (
        \\dsb sy
        \\msr mair_el1, %[mair]
        \\msr tcr_el1, %[tcr]
        \\msr ttbr0_el1, %[ttbr]
        \\isb
        \\tlbi vmalle1
        \\ic iallu
        \\dsb nsh
        \\isb
        \\mrs x8, sctlr_el1
        \\orr x8, x8, #1
        \\orr x8, x8, #(1 << 2)
        \\orr x8, x8, #(1 << 12)
        \\msr sctlr_el1, x8
        \\isb
        :
        : [mair] "r" (MAIR),
          [tcr] "r" (TCR),
          [ttbr] "r" (@intFromPtr(&l1_table)),
        : .{ .x8 = true, .memory = true });
}

pub fn enabled() bool {
    const sctlr = asm volatile ("mrs %[out], sctlr_el1"
        : [out] "=r" (-> u64),
    );
    return (sctlr & 1) != 0;
}
