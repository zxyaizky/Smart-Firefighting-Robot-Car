/* SPDX-License-Identifier: MIT
 * Adapted from SpinalHDL/VexRiscv b6118e5 src/main/c/emulator/src/main.c.
 * Resident single-hart SBI 0.2 BASE/TIME plus v0.1 console. Not OpenSBI.
 */
#include "platform.h"
#define SBI_BASE 0x10u
#define SBI_TIME 0x54494d45u
/* Local, unregistered implementation identifier; do not claim OpenSBI/BBL ID. */
#define LOCAL_IMPL_ID 0x414e4c55u
/* linux-minimal omits SCOUNTEREN along with the actual counter CSRs.
 * Only TM is implemented in firmware; absent cycle/instret bits are WARL zero.
 */
static uint32_t supervisor_counter_enable;

static void stop(void) __attribute__((noreturn));
static void stop(void) {
    csr_write(mie,0);
    for(;;)__asm__ volatile("wfi");
}
static void panic(void) __attribute__((noreturn));
static void panic(void) {
    REG32(TEST_RESULT)=0xbad51001u;
    putString("SBI FATAL\r\n");
    stop();
}
static void timer_set(uint32_t low,uint32_t high) {
    csr_clear(sip,MIP_STIP);
    REG32(TIMECMP+4)=0xffffffffu;
    REG32(TIMECMP)=low;
    REG32(TIMECMP+4)=high;
    csr_set(mie,MIE_MTIE);
}
static int supported(uint32_t eid) {
    return eid==SBI_BASE || eid==SBI_TIME || eid==0 || eid==1 || eid==2 || eid==8;
}
static void ret_sbi(uint32_t *f,int32_t error,uint32_t value) {
    f[10]=(uint32_t)error;f[11]=value;
}
static void ecall(uint32_t *f) {
    uint32_t eid=f[17],fid=f[16],arg=f[10];
    if(eid==0) {timer_set(f[10],f[11]);f[10]=0;}
    else if(eid==1) {putC((char)arg);f[10]=0;}
    else if(eid==2) f[10]=(uint32_t)getC();
    else if(eid==8) {putString("SBI HALT\r\n");stop();}
    else if(eid==SBI_BASE) {
        uint32_t value=0;
        switch(fid) {
        case 0:value=2;break; /* spec major=0, minor=2 */
        case 1:value=LOCAL_IMPL_ID;break;
        case 2:value=0x00010000;break;
        case 3:value=(uint32_t)supported(arg);break;
        case 4:case 5:case 6:value=0;break; /* 0 is legal per SBI BASE */
        default:ret_sbi(f,-2,0);return;
        }
        ret_sbi(f,0,value);
    } else if(eid==SBI_TIME && fid==0) {
        timer_set(f[10],f[11]);ret_sbi(f,0,0);
    } else ret_sbi(f,-2,0);
}

/* Preserve Linux's exception entry ABI when an emulated CSR is not supported.
 * Also used for failed MPRV instruction reads: report the original S/U PC.
 */
static void redirect(uint32_t pc,uint32_t status,uint32_t cause,uint32_t tval) {
    if((status&MSTATUS_MPP)==MSTATUS_MPP)panic();
    csr_write(stval,tval);csr_write(scause,cause);csr_write(sepc,pc);
    csr_write(mepc,csr_read(stvec)&~3u);
    uint32_t next=status&~(MSTATUS_MPRV|MSTATUS_MPP|MSTATUS_SPP|
                           MSTATUS_SIE|MSTATUS_SPIE|MSTATUS_MIE);
    next|=0x800u|MSTATUS_MPIE;
    if(status&MSTATUS_MPP)next|=MSTATUS_SPP;
    if(status&MSTATUS_SIE)next|=MSTATUS_SPIE;
    csr_write(mstatus,next);
}

void trap(void) {
    uint32_t *f=__trap_frame;
    uint32_t cause=csr_read(mcause),pc=csr_read(mepc),status=csr_read(mstatus);
    if(cause==0x80000007u) {
        csr_clear(mie,MIE_MTIE);csr_set(sip,MIP_STIP);return;
    }
    if(cause==9 && (status&MSTATUS_MPP)==0x800u) {
        ecall(f);csr_write(mepc,pc+4);return;
    }
    if(cause==2 && (status&MSTATUS_MPP)!=MSTATUS_MPP) {
        uint32_t insn=0,fetch_cause=0,fetch_tval=0;
        if(read_previous_word(pc,&insn,&fetch_cause,&fetch_tval)) {
            /* MPRV load fault while fetching an instruction -> instruction fault. */
            uint32_t instruction_cause=fetch_cause==13 ? 12 : fetch_cause==4 ? 0 : 1;
            redirect(pc,status,instruction_cause,fetch_tval);return;
        }
        uint32_t csr=insn>>20,rs=(insn>>15)&31u,funct=(insn>>12)&7u;
        int read_only=(funct==2 || funct==3 || funct==6 || funct==7) && rs==0;
        uint32_t rd=(insn>>7)&31u;
        if((insn&127u)==0x73u && csr==0x106u && (status&MSTATUS_MPP)==0x800u &&
           funct!=0 && funct!=4) {
            uint32_t input=(funct&4u) ? rs : f[rs];
            uint32_t old=supervisor_counter_enable,next=old;
            if((funct&3u)==1)next=input;
            else if((funct&3u)==2)next=old|input;
            else next=old&~input;
            supervisor_counter_enable=next&2u;
            if(rd)f[rd]=old;
            csr_write(mepc,pc+4);return;
        }
        int time_allowed=(status&MSTATUS_MPP)!=0 || (supervisor_counter_enable&2u);
        if((insn&127u)==0x73u && (csr==RDTIME || csr==RDTIMEH) && read_only && time_allowed) {
            if(rd)f[rd]=REG32(TIME+(csr==RDTIMEH ? 4u : 0u));
            csr_write(mepc,pc+4);return;
        }
        redirect(pc,status,2,insn);return;
    }
    redirect(pc,status,cause,csr_read(mtval));
}

void sbi_init(void) {
    csr_write(mie,0);csr_clear(mstatus,MSTATUS_MIE|MSTATUS_MPRV);
    csr_write(mtvec,trapEntry);csr_write(mscratch,__trap_frame);
    csr_write(satp,0);__asm__ volatile("sfence.vma" ::: "memory");
    REG32(0xf0001010u)=0;REG32(0xf0001014u)=0;REG32(0xf0001018u)=0;
    REG32(MSIP)=0;REG32(TIMECMP+4)=0xffffffffu;REG32(TIMECMP)=0xffffffffu;
    csr_write(mip,0);csr_write(sie,0);
    supervisor_counter_enable=2;
    /* Illegal instructions stay in M for time/timeh; S ecall is the SBI entry. */
    csr_write(medeleg,0xb1fbu);csr_write(mideleg,0x222u);
    putString("VexRiscv B SBI 0.2\r\n");
    if(REG32((uintptr_t)__dtb_start)!=0xedfe0dd0u)panic();
#if NEXT_IS_LINUX
    if(REG32(NEXT_ENTRY+0x38u)!=0x05435352u) {
        REG32(TEST_RESULT)=0xbad51002u;
        putString("LINUX IMAGE MISSING\r\n");stop();
    }
#endif
    csr_write(mepc,NEXT_ENTRY);
    csr_write(mstatus,0x800u|MSTATUS_MPIE);
}
