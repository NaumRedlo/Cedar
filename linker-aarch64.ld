/* Cedar kernel linker script (aarch64, direct kernel-image boot).
   Linked at the physical address where QEMU's -kernel loader places the
   image on the virt machine: RAM base (0x40000000) + text_offset (0x80000).
   The MMU is off at entry; everything runs at physical addresses until
   Cedar sets up its own page tables. */

OUTPUT_FORMAT(elf64-littleaarch64)

ENTRY(_start)

SECTIONS
{
    . = 0x40080000;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    . = ALIGN(4096);

    .rodata : {
        *(.rodata .rodata.*)
    }

    . = ALIGN(4096);

    .data : {
        *(.data .data.*)
    }

    . = ALIGN(4096);

    .bss : {
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

    __image_size = . - 0x40080000;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
