# Cedar

A hobby ARM (aarch64) operating system kernel written in Zig — with **no
bootloader**. The boot path belongs to the kernel: a raw image with a
Linux arm64 boot header is loaded directly by QEMU's `-kernel` (and, in
the future, by the Raspberry Pi firmware as `kernel8.img`), and every
instruction from the entry point on is Cedar's own code.

Cedar is **ARM-only by design**: the target hardware is Apple Silicon
(via QEMU/HVF) and, eventually, Raspberry Pi. There is no x86_64 support
and none is planned.

Current state: `src/boot.S` parks secondary cores, clears BSS and sets up
the stack; the kernel prints `Hello, Cedar!` and the device tree address
over the PL011 serial port.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.16.0
- `qemu-system-aarch64`

## Building and running

```sh
zig build       # kernel ELF + raw boot image (zig-out/bin/cedar.img)
zig build run   # boot cedar.img in QEMU (serial output on stdio)
```

## Layout

- `src/boot.S` — entry point: arm64 boot header, core parking, BSS, stack
- `src/main.zig` — kmain, panic handler, kprint/kprintf
- `src/arch/aarch64.zig` — PL011 UART at its physical address, wfi halt
- `src/console.zig`, `src/font8x8.zig` — framebuffer text console
  (dormant until Cedar drives the display itself: ramfb on QEMU virt,
  mailbox on Raspberry Pi)
- `linker-aarch64.ld` — links at 0x40080000 (virt RAM base + text_offset),
  reserves the boot stack, exports BSS/image-size symbols

## Roadmap

Exception vectors (VBAR_EL1) → device tree parsing → own MMU/page tables
→ framebuffer driver (ramfb/mailbox) → timer + scheduler → Raspberry Pi
board support.
