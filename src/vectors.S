// aarch64 exception vector table: 16 entries of 128 bytes, the table
// itself aligned to 2 KiB (VBAR_EL1 requires it). Every entry saves the
// full context — x0-x30 plus ELR/SPSR — and hands off to the Zig
// handler with the vector index and a pointer to the frame. If the
// handler returns (serviced IRQ), the frame is restored and we eret;
// fatal exceptions never come back.
//
// Frame layout (272 bytes, must match exceptions.Frame):
//   [0..240)   x0-x29 as pairs
//   [240]      x30
//   [248]      elr_el1
//   [256]      spsr_el1
//   [264]      sp_el0 (user stack pointer, live once EL0 exists)

.macro ventry index
.align 7
    sub     sp, sp, #272
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
    str     x30,      [sp, #240]
    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    stp     x0, x1,   [sp, #248]
    mrs     x0, sp_el0
    str     x0,       [sp, #264]
    mov     x0, #\index
    mov     x1, sp
    b       exception_common
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

.align 2
exception_common:
    bl      handleException
    // handleException returns the frame to resume (x0). Normally it is
    // the same frame; on a context switch it belongs to another thread
    // and lives on that thread's stack.
    mov     sp, x0
    ldp     x0, x1,   [sp, #248]
    msr     elr_el1, x0
    msr     spsr_el1, x1
    ldr     x0,       [sp, #264]
    msr     sp_el0, x0
    ldp     x0, x1,   [sp, #16*0]
    ldp     x2, x3,   [sp, #16*1]
    ldp     x4, x5,   [sp, #16*2]
    ldp     x6, x7,   [sp, #16*3]
    ldp     x8, x9,   [sp, #16*4]
    ldp     x10, x11, [sp, #16*5]
    ldp     x12, x13, [sp, #16*6]
    ldp     x14, x15, [sp, #16*7]
    ldp     x16, x17, [sp, #16*8]
    ldp     x18, x19, [sp, #16*9]
    ldp     x20, x21, [sp, #16*10]
    ldp     x22, x23, [sp, #16*11]
    ldp     x24, x25, [sp, #16*12]
    ldp     x26, x27, [sp, #16*13]
    ldp     x28, x29, [sp, #16*14]
    ldr     x30,      [sp, #240]
    add     sp, sp, #272
    eret
