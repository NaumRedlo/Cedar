// Cedar boot stub — the first code that runs. No bootloader: QEMU's
// -kernel loader (or, later, the Raspberry Pi firmware) places this
// image in RAM and jumps to the first instruction.
//
// The 64-byte header below follows the Linux arm64 boot protocol
// (Documentation/arch/arm64/booting.rst), which QEMU recognises: it
// loads the image at 2 MiB-aligned RAM base + text_offset and enters
// at the start with x0 = physical address of the device tree blob.

.section .text.boot
.global _start

_start:
    b       entry                 // code0: jump over the header
    .long   0                     // code1
    .quad   0x80000               // text_offset: load offset from RAM base
    .quad   __image_size          // image_size
    .quad   0                     // flags: LE, 4K pages
    .quad   0                     // res2
    .quad   0                     // res3
    .quad   0                     // res4
    .ascii  "ARM\x64"             // magic
    .long   0                     // res5

entry:
    // Park every core except core 0 — SMP comes much later.
    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
    cbz     x1, core0
halt_secondary:
    wfe
    b       halt_secondary

core0:
    // Preserve the DTB pointer QEMU handed us in x0.
    mov     x19, x0

    // Zero .bss (boot protocol does not guarantee it is cleared).
    adrp    x1, __bss_start
    add     x1, x1, :lo12:__bss_start
    adrp    x2, __bss_end
    add     x2, x2, :lo12:__bss_end
bss_loop:
    cmp     x1, x2
    b.hs    bss_done
    str     xzr, [x1], #8
    b       bss_loop
bss_done:

    // Stack grows down from __stack_top (reserved in the linker script).
    adrp    x1, __stack_top
    add     x1, x1, :lo12:__stack_top
    mov     sp, x1

    mov     x0, x19
    bl      kmain

    // kmain never returns; if it somehow does, halt.
hang:
    wfe
    b       hang
