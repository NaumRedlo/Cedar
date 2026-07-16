/* Cedar kernel linker script (aarch64, higher-half).
   The .boot section keeps physical addresses (VMA = LMA): it runs with
   the MMU off. Everything else is linked at HHDM + physical — the
   AT() directives keep load addresses contiguous so objcopy still
   produces a flat bootable image with the header at offset 0. */

KERNEL_PHYS = 0x40080000;
HHDM_BASE   = 0xffffff8000000000;

OUTPUT_FORMAT(elf64-littleaarch64)

ENTRY(_start)

SECTIONS
{
    . = KERNEL_PHYS;

    .boot : {
        KEEP(*(.text.boot))
    }

    . = ALIGN(4096);
    . += HHDM_BASE;

    .text : AT(ADDR(.text) - HHDM_BASE) {
        *(.text .text.*)
    }

    . = ALIGN(4096);

    .rodata : AT(ADDR(.rodata) - HHDM_BASE) {
        *(.rodata .rodata.*)
    }

    . = ALIGN(4096);

    .data : AT(ADDR(.data) - HHDM_BASE) {
        *(.data .data.*)
    }

    . = ALIGN(4096);

    .bss : AT(ADDR(.bss) - HHDM_BASE) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;

        /* 64 KiB boot stack for core 0. */
        . = ALIGN(16);
        __stack_bottom = .;
        . += 0x10000;
        __stack_top = .;
    }

    __image_size = (. - HHDM_BASE) - KERNEL_PHYS;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
