# Cedar

A hobby x86_64 operating system kernel written in Zig, booted by the
[Limine](https://github.com/limine-bootloader/limine) boot protocol.

Current state: boots in QEMU (BIOS or UEFI) and prints `Hello, Cedar!`
over the COM1 serial port.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.16.0
- `xorriso` (ISO assembly)
- `qemu-system-x86_64` (running the kernel)
- Limine binaries, cloned into the project root:

```sh
git clone --branch=v9.x-binary --depth=1 https://github.com/limine-bootloader/limine.git
```

## Building and running

```sh
zig build        # compile the kernel ELF into zig-out/bin/kernel
zig build iso    # assemble bootable cedar.iso (runs scripts/mkiso.sh)
zig build run    # boot cedar.iso in QEMU, serial output on stdio
```

## Layout

- `src/main.zig` — kernel entry point, Limine protocol markers, serial driver
- `linker.ld` — linker script placing the kernel in the top 2 GiB (Limine spec)
- `limine.conf` — boot menu entry
- `scripts/mkiso.sh` — ISO assembly recipe (follows limine-c-template)
