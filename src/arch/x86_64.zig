// x86_64: serial output through legacy COM1 port I/O; halt via hlt.

const COM1: u16 = 0x3f8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn init() void {
    outb(COM1 + 1, 0x00); // disable UART interrupts
    outb(COM1 + 3, 0x80); // DLAB on to set baud divisor
    outb(COM1 + 0, 0x01); // divisor 1 -> 115200 baud
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8 bits, no parity, 1 stop bit; DLAB off
    outb(COM1 + 2, 0xc7); // enable + clear FIFOs
}

pub fn serialWriteByte(byte: u8) void {
    // Wait until the transmit holding register is empty (LSR bit 5).
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, byte);
}

pub fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
