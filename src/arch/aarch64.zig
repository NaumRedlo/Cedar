// aarch64: serial output through the PL011 UART of QEMU's `virt` machine,
// reached via Limine's higher-half direct map (HHDM); halt via wfi.
//
// NOTE: the Limine spec only guarantees HHDM mappings for memory-map
// regions; MMIO at 0x0900_0000 may or may not be mapped. The framebuffer
// is painted before the first serial write so there is visible proof of
// life even if the UART access faults. To be verified in QEMU.

const limine = @import("../limine.zig");

const PL011_BASE_PHYS: u64 = 0x0900_0000;
const FR_TXFF: u32 = 1 << 5;

var uart: ?[*]volatile u32 = null;

pub fn init() void {
    const hhdm = limine.hhdm_request.response orelse return;
    uart = @ptrFromInt(hhdm.offset + PL011_BASE_PHYS);
}

pub fn serialWriteByte(byte: u8) void {
    const u = uart orelse return;
    // Wait while the transmit FIFO is full (UARTFR at 0x18).
    while ((u[0x18 / 4] & FR_TXFF) != 0) {}
    u[0] = byte; // UARTDR
}

pub fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
