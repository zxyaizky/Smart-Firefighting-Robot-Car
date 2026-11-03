/* SPDX-License-Identifier: MIT; based on upstream readWord's MPRV technique.
 * MTVEC is write-only on this CPU: restore trapEntry without reading MTVEC.
 */
    .option norvc
    .option norelax
    .text
    .globl read_previous_word
read_previous_word:
    csrr t3,mstatus
    li a4,1
    li a5,0
    li t4,0
    li t5,0
    la t0,1f
    csrw mtvec,t0
    li t0,0xa0000
    csrs mstatus,t0
    lw a5,0(a0)
    li a4,0
    j 2f
    .balign 4
1:  csrr t4,mcause
    csrr t5,mtval
2:  csrw mstatus,t3
    la t0,trapEntry
    csrw mtvec,t0
    sw a5,0(a1)
    sw t4,0(a2)
    sw t5,0(a3)
    mv a0,a4
    ret
