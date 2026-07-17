// Cedar boot stub — the first code that runs. No bootloader: QEMU's
// -kernel loader places this image in RAM and jumps to the first
// instruction.
//
// This stub now owns the MMU bring-up: it builds a single L1 table
// (1 GiB blocks: device GB0, normal RAM GBs 1-8) used by BOTH TTBR0
// and TTBR1 — the indices coincide because HHDM's low 39 bits are
// zero. It enables translation, jumps to the higher-half alias, kills
// TTBR0 walks (null derefs fault from then on), and only then enters
// Zig code, which is all linked at HHDM + physical.

.equ HHDM_BASE,    0xffffff8000000000
.equ L1_TABLE,     0x40070000            // one free page below the kernel
.equ MAIR_VAL,     0x04ff                // attr0 normal WB, attr1 device
// T0SZ/T1SZ=25 (39-bit), 4K granules, WBWA inner-shareable, 40-bit IPS
.equ TCR_VAL,      0x2B5193519
.equ BLOCK_NORMAL, 0x701                 // valid | attr0 | SH inner | AF
.equ BLOCK_DEVICE, 0x405                 // valid | attr1 | AF (+PXN/UXN below)

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
    // Only core 0 runs the primary path. Secondaries are started later,
    // on demand, via PSCI CPU_ON pointing at secondary_start — so any
    // core that lands here at power-on (before we ask) just waits.
    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
    cbz     x1, core0
halt_secondary:
    wfe
    b       halt_secondary

core0:
    // Preserve the DTB pointer QEMU handed us in x0.
    mov     x19, x0

    // Build the L1 table (MMU off, physical addresses).
    ldr     x0, =L1_TABLE
    mov     x1, #512
1:  sub     x1, x1, #1
    str     xzr, [x0, x1, lsl #3]
    cbnz    x1, 1b

    // [0]: 1 GiB device block (UART, GIC, flash), never executable.
    ldr     x2, =BLOCK_DEVICE
    orr     x2, x2, #(3 << 53)    // PXN | UXN
    str     x2, [x0]

    // [1..8]: normal write-back RAM blocks (covers up to 8 GiB boards).
    ldr     x5, =BLOCK_NORMAL
    mov     x3, #1
2:  lsl     x4, x3, #30
    orr     x4, x4, x5
    str     x4, [x0, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #9
    b.lo    2b

    // Translation regime: same table for both halves.
    ldr     x1, =MAIR_VAL
    msr     mair_el1, x1
    ldr     x1, =TCR_VAL
    msr     tcr_el1, x1
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x0
    dsb     sy
    isb
    tlbi    vmalle1
    ic      iallu
    dsb     nsh
    isb
    mrs     x1, sctlr_el1
    orr     x1, x1, #1            // M: translation on
    orr     x1, x1, #(1 << 2)     // C: data cache
    orr     x1, x1, #(1 << 12)    // I: instruction cache
    msr     sctlr_el1, x1
    isb

    // Leave the identity map behind: absolute jump to the high alias.
    ldr     x1, =high_entry
    br      x1
.ltorg

.section .text
high_entry:
    // Running in the higher half now. Disable TTBR0 walks so that low
    // addresses — null pointers first of all — fault loudly.
    mrs     x1, tcr_el1
    orr     x1, x1, #(1 << 7)     // EPD0
    msr     tcr_el1, x1
    tlbi    vmalle1
    dsb     nsh
    isb

    // Zero .bss (adrp works here: targets are within range of high PC).
    adrp    x1, __bss_start
    add     x1, x1, :lo12:__bss_start
    adrp    x2, __bss_end
    add     x2, x2, :lo12:__bss_end
3:  cmp     x1, x2
    b.hs    4f
    str     xzr, [x1], #8
    b       3b
4:

    // Stack grows down from __stack_top (reserved in the linker script).
    adrp    x1, __stack_top
    add     x1, x1, :lo12:__stack_top
    mov     sp, x1

    // kmain gets the DTB through the direct map.
    ldr     x1, =HHDM_BASE
    add     x0, x19, x1
    bl      kmain

    // kmain never returns; if it somehow does, halt.
hang:
    wfe
    b       hang

// Secondary-core entry, reached via PSCI CPU_ON with the MMU off and
// the cpu index in x0 (PSCI context_id). The L1 table core0 built is
// still live at its fixed physical address, so this core only loads the
// translation registers and enables the MMU — it doesn't rebuild them.
.section .text.boot
.global secondary_start
secondary_start:
    mov     x20, x0               // cpu index

    ldr     x0, =L1_TABLE
    ldr     x1, =MAIR_VAL
    msr     mair_el1, x1
    ldr     x1, =TCR_VAL
    msr     tcr_el1, x1
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x0
    dsb     sy
    isb
    tlbi    vmalle1
    ic      iallu
    dsb     nsh
    isb
    mrs     x1, sctlr_el1
    orr     x1, x1, #1
    orr     x1, x1, #(1 << 2)
    orr     x1, x1, #(1 << 12)
    msr     sctlr_el1, x1
    isb

    ldr     x1, =secondary_high
    br      x1
.ltorg

.section .text
secondary_high:
    // Higher half now: disable TTBR0 walks like the primary did.
    mrs     x1, tcr_el1
    orr     x1, x1, #(1 << 7)     // EPD0
    msr     tcr_el1, x1
    tlbi    vmalle1
    dsb     nsh
    isb

    // Per-core stack: secondary_stacks[cpu], set up by smp.startCores.
    adrp    x1, secondary_stacks
    add     x1, x1, :lo12:secondary_stacks
    ldr     x2, [x1, x20, lsl #3]
    mov     sp, x2

    mov     x0, x20
    bl      secondaryMain

secondary_hang:
    wfe
    b       secondary_hang
