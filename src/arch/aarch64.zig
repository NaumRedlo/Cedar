// aarch64: serial output through the PL011 UART of QEMU's `virt`
// machine, accessed at its physical address — the MMU is off until
// Cedar builds its own page tables. Halt via wfi.
//
// 0x0900_0000 is where the virt machine places the PL011; on real
// boards (Raspberry Pi) the base differs and will come from the
// device tree once Cedar parses it.

const PL011_BASE: u64 = 0x0900_0000;
const FR_TXFF: u32 = 1 << 5;

const uart: [*]volatile u32 = @ptrFromInt(PL011_BASE);

pub fn init() void {}

pub fn serialWriteByte(byte: u8) void {
    // Wait while the transmit FIFO is full (UARTFR at 0x18).
    while ((uart[0x18 / 4] & FR_TXFF) != 0) {}
    uart[0] = byte; // UARTDR
}

pub fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
