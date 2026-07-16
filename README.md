# Cedar

A hobby operating system kernel written in Zig, booted by the
[Limine](https://github.com/limine-bootloader/limine) boot protocol.

**Primary architecture: aarch64** (targeting Apple Silicon Macs via QEMU/HVF
and, eventually, Raspberry Pi hardware). x86_64 is kept as a secondary
target — it is what the current Intel development machine emulates fastest.

Current state: boots in QEMU, paints a gradient on the framebuffer and
prints `Hello, Cedar!` over the serial port.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.16.0
- `xorriso` (ISO assembly)
- QEMU (`qemu-system-aarch64` / `qemu-system-x86_64`)
- Limine binaries, cloned into the project root:

```sh
git clone --branch=v9.x-binary --depth=1 https://github.com/limine-bootloader/limine.git
```

## Building and running

```sh
zig build                    # compile the kernel ELF (aarch64 by default)
zig build iso                # assemble bootable cedar-aarch64.iso
zig build run                # boot it in QEMU (serial output on stdio)

zig build run -Darch=x86_64  # the same, for x86_64
```

On ARM there is no BIOS: the ISO is UEFI-only and QEMU boots it through the
edk2 firmware that ships with QEMU (`share/qemu/edk2-aarch64-code.fd`).

## Layout

- `src/main.zig` — arch-independent kernel entry point
- `src/limine.zig` — Limine protocol structs and request slots
- `src/arch/aarch64.zig` — PL011 UART (via Limine's HHDM), wfi halt
- `src/arch/x86_64.zig` — COM1 serial via port I/O, hlt halt
- `linker-aarch64.ld`, `linker-x86_64.ld` — per-arch linker scripts
- `limine.conf` — boot menu entry
- `scripts/mkiso.sh` — per-arch ISO assembly (follows limine-c-template)
