/* SPDX-License-Identifier: MIT; port of upstream/src/start.S. */
    .option norvc
    .option norelax
    .section .init,"ax",@progbits
    .globl _start
_start:
    .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\reg,0
    .endr
    la sp,__trap_frame
    la t0,__bss_start
    la t1,__bss_end
1:  bgeu t0,t1,2f
    sw zero,0(t0)
    addi t0,t0,4
    j 1b
2:  call sbi_init
    li a0,0
    la a1,__dtb_start
    li ra,0
    mret
