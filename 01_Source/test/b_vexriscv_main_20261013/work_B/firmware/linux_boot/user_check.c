/* RV32 Linux U-mode acceptance: real syscalls, demand paging and unaligned traps. */
typedef unsigned int u32;
static long call(long n,long x,long y,long z,long w,long v,long q) {
    register long a0 __asm__("a0")=x,a1 __asm__("a1")=y,a2 __asm__("a2")=z;
    register long a3 __asm__("a3")=w,a4 __asm__("a4")=v,a5 __asm__("a5")=q;
    register long a7 __asm__("a7")=n;
    __asm__ volatile("ecall":"+r"(a0):"r"(a1),"r"(a2),"r"(a3),"r"(a4),"r"(a5),"r"(a7):"memory");
    return a0;
}
static void done(int good) __attribute__((noreturn));
static void done(int good) {
    static const char ok[]="LINUX UMODE MMU UNALIGNED TIMER PASS\n";
    static const char bad[]="LINUX USER CHECK FAIL\n";
    call(64,1,(long)(good?ok:bad),good?sizeof(ok)-1:sizeof(bad)-1,0,0,0);
    call(93,good?0:1,0,0,0,0,0);
    for(;;) {}
}
void _start(void) {
    long mapped=call(222,0,8192,3,0x22,-1,0);
    if((u32)mapped>=0xfffff001u)done(0);
    volatile unsigned char *p=(void *)mapped;
    u32 value;
    /* Force real misaligned instructions, including crossing a page boundary. */
    for(u32 offset=1;offset<=4095;offset+=4094) {
        volatile unsigned char *at=p+offset;
        value=0x89abcdefu;
        __asm__ volatile("sw %1,0(%0)"::"r"(at),"r"(value):"memory");
        if(at[0]!=0xef || at[1]!=0xcd || at[2]!=0xab || at[3]!=0x89)done(0);
        __asm__ volatile("lw %0,0(%1)":"=r"(value):"r"(at):"memory");
        if(value!=0x89abcdefu)done(0);
        __asm__ volatile("lh %0,0(%1)":"=r"(value):"r"(at):"memory");
        if(value!=0xffffcdefu)done(0);
        __asm__ volatile("lhu %0,0(%1)":"=r"(value):"r"(at):"memory");
        if(value!=0xcdefu)done(0);
        value=0xa123;
        __asm__ volatile("sh %1,0(%0)"::"r"(at),"r"(value):"memory");
        if(at[0]!=0x23 || at[1]!=0xa1)done(0);
    }
    /* Actual RV32A operations in the user address space. */
    volatile u32 *atomic=(volatile u32 *)(p+16);
    *atomic=7;value=5;
    __asm__ volatile("amoadd.w %0,%2,(%1)":"=r"(value):"r"(atomic),"r"(value):"memory");
    if(value!=7 || *atomic!=12)done(0);
    u32 first[4],last[4];
    if(call(403,1,(long)first,0,0,0,0))done(0);
    int advanced=0;
    for(int i=0;i<10000;i++) {
        if(call(403,1,(long)last,0,0,0,0))done(0);
        if(last[0]!=first[0] || last[1]!=first[1] || last[2]!=first[2] || last[3]!=first[3]) {
            advanced=1;break;
        }
    }
    if(!advanced || call(215,mapped,8192,0,0,0,0))done(0);
    done(1);
}
