#!/bin/sh
# Assemble a bootable ISO from the built kernel and Limine binaries.
# Usage: mkiso.sh [aarch64|x86_64]   (default: aarch64)
# ISO recipes follow limine-c-template's GNUmakefile:
#   x86_64  — BIOS + UEFI hybrid
#   aarch64 — UEFI only (no BIOS on ARM)
set -e
cd "$(dirname "$0")/.."

ARCH="${1:-aarch64}"
ISO="cedar-$ARCH.iso"

if [ ! -d limine ]; then
    echo "limine/ not found. Run:" >&2
    echo "  git clone --branch=v9.x-binary --depth=1 https://github.com/limine-bootloader/limine.git" >&2
    exit 1
fi

rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
cp zig-out/bin/kernel iso_root/boot/
cp limine.conf iso_root/boot/limine/

case "$ARCH" in
x86_64)
    # Build the `limine` host tool for bios-install (no-op after first run).
    make -C limine >/dev/null
    cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
    cp limine/BOOTX64.EFI limine/BOOTIA32.EFI iso_root/EFI/BOOT/
    xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
        -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o "$ISO" 2>/dev/null
    ./limine/limine bios-install "$ISO" 2>/dev/null
    ;;
aarch64)
    cp limine/limine-uefi-cd.bin iso_root/boot/limine/
    cp limine/BOOTAA64.EFI iso_root/EFI/BOOT/
    xorriso -as mkisofs -R -r -J -hfsplus -apm-block-size 2048 \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o "$ISO" 2>/dev/null
    ;;
*)
    echo "unknown arch: $ARCH" >&2
    exit 1
    ;;
esac

echo "$ISO ready"
