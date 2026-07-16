// aarch64 exception vector table: 16 entries of 128 bytes, the table
// itself aligned to 2 KiB (VBAR_EL1 requires it). Every entry saves
// x0-x30 and hands off to the Zig handler with the vector index and a
// pointer to the saved frame. Handlers never return for now, so no
// restore path exists yet.

.macro ventry index
.align 7
    sub     sp, sp, #256
    stp     x0, x1,   [sp, #16*0]
    stp     x2, x3,   [sp, #16*1]
    stp     x4, x5,   [sp, #16*2]
    stp     x6, x7,   [sp, #16*3]
    stp     x8, x9,   [sp, #16*4]
    stp     x10, x11, [sp, #16*5]
    stp     x12, x13, [sp, #16*6]
    stp     x14, x15, [sp, #16*7]
    stp     x16, x17, [sp, #16*8]
    stp     x18, x19, [sp, #16*9]
    stp     x20, x21, [sp, #16*10]
    stp     x22, x23, [sp, #16*11]
    stp     x24, x25, [sp, #16*12]
    stp     x26, x27, [sp, #16*13]
    stp     x28, x29, [sp, #16*14]
    str     x30,      [sp, #16*15]
    mov     x0, #\index
    mov     x1, sp
    bl      handleException
.endm

.section .text
.align 11
.global exception_vectors
exception_vectors:
    ventry  0   // sync,   current EL, SP_EL0
    ventry  1   // irq,    current EL, SP_EL0
    ventry  2   // fiq,    current EL, SP_EL0
    ventry  3   // serror, current EL, SP_EL0
    ventry  4   // sync,   current EL, SP_ELx
    ventry  5   // irq,    current EL, SP_ELx
    ventry  6   // fiq,    current EL, SP_ELx
    ventry  7   // serror, current EL, SP_ELx
    ventry  8   // sync,   lower EL, aarch64
    ventry  9   // irq,    lower EL, aarch64
    ventry  10  // fiq,    lower EL, aarch64
    ventry  11  // serror, lower EL, aarch64
    ventry  12  // sync,   lower EL, aarch32
    ventry  13  // irq,    lower EL, aarch32
    ventry  14  // fiq,    lower EL, aarch32
    ventry  15  // serror, lower EL, aarch32
