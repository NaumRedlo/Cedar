/* Cedar kernel linker script (aarch64, Limine boot protocol).
   Based on limine-c-template/kernel/linker-scripts/aarch64.lds */

OUTPUT_FORMAT(elf64-littleaarch64)

ENTRY(kmain)

/* Separate PT_LOAD program headers so the bootloader maps each region
   with the right MMU permissions. */
PHDRS
{
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
}

SECTIONS
{
    /* Topmost 2 GiB of the address space, as the Limine spec mandates. */
    . = 0xffffffff80000000;

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    .note.gnu.build-id : {
        *(.note.gnu.build-id)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        *(.data .data.*)
    } :data

    /* .bss must be the last thing mapped to :data, otherwise the binary
       gets padded with unnecessary zeros. */
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /* .note.* and .eh_frame* may cause issues on some hosts. */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
