/* Runs on the PH1P35 hard MCU, not on VexRiscv. XIP entry 0x20e00000. */
.section .text
.global _start
_start:
    lui t0, 0x80000
poll:
    lw t1, 0(t0)
    andi t1, t1, 1
    beq t1, zero, poll
    lw t2, 4(t0)
    lw t3, 0(t2)
    sw t3, 8(t0)
    j poll
