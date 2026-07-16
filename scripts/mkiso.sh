#!/bin/sh
# Assemble the bootable aarch64 ISO from the built kernel and Limine
# binaries. UEFI-only — there is no BIOS on ARM.
# Recipe follows limine-c-template's GNUmakefile.
set -e
cd "$(dirname "$0")/.."

if [ ! -d limine ]; then
    echo "limine/ not found. Run:" >&2
    echo "  git clone --branch=v9.x-binary --depth=1 https://github.com/limine-bootloader/limine.git" >&2
    exit 1
fi

rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
cp zig-out/bin/kernel iso_root/boot/
cp limine.conf limine/limine-uefi-cd.bin iso_root/boot/limine/
cp limine/BOOTAA64.EFI iso_root/EFI/BOOT/

xorriso -as mkisofs -R -r -J -hfsplus -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o cedar.iso 2>/dev/null

echo "cedar.iso ready"
