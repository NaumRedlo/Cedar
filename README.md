# Cedar

A hobby ARM (aarch64) operating system kernel written in Zig, booted by the
[Limine](https://github.com/limine-bootloader/limine) boot protocol.

Cedar is **ARM-only by design**: the target hardware is Apple Silicon
(via QEMU/HVF) and, eventually, Raspberry Pi. There is no x86_64 support
and none is planned.

Current state: boots in QEMU, paints a gradient on the framebuffer and
prints `Hello, Cedar!` over the PL011 serial port.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.16.0
- `xorriso` (ISO assembly)
- `qemu-system-aarch64`
- Limine binaries, cloned into the project root:

```sh
git clone --branch=v9.x-binary --depth=1 https://github.com/limine-bootloader/limine.git
```

## Building and running

```sh
zig build       # compile the kernel ELF into zig-out/bin/kernel
zig build iso   # assemble bootable cedar.iso (UEFI-only; no BIOS on ARM)
zig build run   # boot cedar.iso in QEMU (serial output on stdio)
```

QEMU boots the ISO through the edk2 UEFI firmware that ships with QEMU
itself (`share/qemu/edk2-aarch64-code.fd`).

## Layout

- `src/main.zig` — kernel entry point
- `src/limine.zig` — Limine protocol structs and request slots
- `src/arch/aarch64.zig` — PL011 UART (via Limine's HHDM), wfi halt
- `linker-aarch64.ld` — linker script placing the kernel in the top 2 GiB
- `limine.conf` — boot menu entry
- `scripts/mkiso.sh` — ISO assembly (follows limine-c-template)
