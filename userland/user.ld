/* Cedar user program: a flat binary linked at the fixed user code VA
   (must match user.zig CODE_VA). The kernel copies it page by page. */

OUTPUT_FORMAT(elf64-littleaarch64)

ENTRY(_start)

SECTIONS
{
    . = 0x10000000;

    .text : {
        KEEP(*(.text.entry))
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
