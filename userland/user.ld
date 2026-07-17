/* Cedar user program: a static aarch64 ELF executable linked at the
   fixed user code VA (must be inside user.zig's [CODE_VA, STACK_TOP)).
   Two page-aligned PT_LOAD segments — R+X code, R+W data — so the
   kernel's ELF loader can map each with the right permissions. */

OUTPUT_FORMAT(elf64-littleaarch64)

ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5); /* R + X */
    data PT_LOAD FLAGS(6); /* R + W */
}

SECTIONS
{
    . = 0x10000000;

    .text : {
        KEEP(*(.text.entry))
        *(.text .text.*)
    } :text

    .rodata : {
        *(.rodata .rodata.*)
    } :text

    . = ALIGN(4096);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
