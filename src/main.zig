const std = @import("std");

// Limine boot protocol markers. The bootloader scans the .limine_requests
// section for these magic values; magic numbers are from limine.h (v9.x).
export var limine_requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

// Base revision 3: bootloader sets the last element to 0 if supported.
export var limine_base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3,
};

export var limine_requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

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

fn serialInit() void {
    outb(COM1 + 1, 0x00); // disable UART interrupts
    outb(COM1 + 3, 0x80); // DLAB on to set baud divisor
    outb(COM1 + 0, 0x01); // divisor 1 -> 115200 baud
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8 bits, no parity, 1 stop bit; DLAB off
    outb(COM1 + 2, 0xc7); // enable + clear FIFOs
}

fn serialWriteByte(byte: u8) void {
    // Wait until the transmit holding register is empty (LSR bit 5).
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, byte);
}

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') serialWriteByte('\r');
        serialWriteByte(c);
    }
}

fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    serialWrite("KERNEL PANIC: ");
    serialWrite(msg);
    serialWrite("\n");
    halt();
}

export fn kmain() callconv(.c) noreturn {
    // Volatile read: the bootloader rewrites this value at load time.
    const revision_ok = @as(*volatile u64, &limine_base_revision[2]).* == 0;
    serialInit();
    if (!revision_ok) {
        serialWrite("Limine base revision 3 not supported by loader\n");
        halt();
    }
    serialWrite("Hello, Cedar!\n");
    halt();
}
