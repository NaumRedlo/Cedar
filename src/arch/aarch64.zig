// aarch64: serial output through the PL011 UART of QEMU's `virt`
// machine, accessed at its physical address — the MMU is off until
// Cedar builds its own page tables. Halt via wfi.
//
// 0x0900_0000 is where the virt machine places the PL011; on real
// boards (Raspberry Pi) the base differs and will come from the
// device tree once Cedar parses it.

const PL011_BASE_DEFAULT: u64 = 0x0900_0000;
const FR_TXFF: u32 = 1 << 5;

var uart_base: u64 = PL011_BASE_DEFAULT;

pub fn init() void {}

// Called once the device tree told us where the UART really lives.
pub fn setUartBase(addr: u64) void {
    uart_base = addr;
}

fn uart() [*]volatile u32 {
    return @ptrFromInt(uart_base);
}

pub fn serialWriteByte(byte: u8) void {
    // Wait while the transmit FIFO is full (UARTFR at 0x18).
    while ((uart()[0x18 / 4] & FR_TXFF) != 0) {}
    uart()[0] = byte; // UARTDR
}

pub fn enableIrqs() void {
    asm volatile ("msr daifclr, #2");
}

// Mask IRQs, returning the previous DAIF state for irqRestore.
pub fn irqSave() u64 {
    const daif = asm volatile ("mrs %[out], daif"
        : [out] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

pub fn irqRestore(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
    );
}

pub fn currentEl() u64 {
    const el = asm volatile ("mrs %[out], currentel"
        : [out] "=r" (-> u64),
    );
    return (el >> 2) & 3;
}

pub fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
