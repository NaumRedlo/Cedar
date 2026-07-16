// Higher-half memory layout. The MMU is brought up by boot.S before
// any Zig code runs: one L1 table (1 GiB blocks) serves both TTBR0
// (identity, only during the boot transition) and TTBR1 (the direct
// map). TTBR0 walks are disabled once execution reaches the high half,
// so every low-address dereference — null pointers included — faults.

pub const HHDM: u64 = 0xffffff80_00000000;

// The boot L1 table lives in one page just below the kernel image;
// mem.zig must keep it reserved.
pub const BOOT_TABLE_PHYS: u64 = 0x4007_0000;
pub const BOOT_TABLE_PAGES: u64 = 1;

pub fn p2v(phys: u64) u64 {
    return HHDM + phys;
}

pub fn v2p(virt: u64) u64 {
    return virt - HHDM;
}

pub fn enabled() bool {
    const sctlr = asm volatile ("mrs %[out], sctlr_el1"
        : [out] "=r" (-> u64),
    );
    return (sctlr & 1) != 0;
}

pub fn lowHalfDisabled() bool {
    const tcr = asm volatile ("mrs %[out], tcr_el1"
        : [out] "=r" (-> u64),
    );
    return (tcr & (1 << 7)) != 0;
}
