/* Bootstrap only: copy a little-endian length followed by exactly that many bytes.
 * Linux RV32 syscalls avoid a libc-sized bootstrap and one syscall per byte. */
static long call(long number, long fd, void *buffer, unsigned size) {
    register long a0 __asm__("a0")=fd;
    register void *a1 __asm__("a1")=buffer;
    register unsigned a2 __asm__("a2")=size;
    register long a7 __asm__("a7")=number;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1),"r"(a2),"r"(a7) : "memory");
    return a0;
}

__attribute__((noreturn)) static void finish(long status) {
    call(93,status,(void *)0,0);
    __builtin_unreachable();
}

static void exact(long number, long fd, unsigned char *buffer, unsigned size) {
    while(size) {
        long n=call(number,fd,buffer,size);
        if(n==-4) continue; /* EINTR */
        if(n<=0 || (unsigned long)n>size) finish(31);
        buffer+=n;size-=(unsigned)n;
    }
}

__attribute__((noreturn)) void _start(void) {
    unsigned char header[4],buffer[512];
    unsigned left;
    exact(63,0,header,4);
    left=(unsigned)header[0]|((unsigned)header[1]<<8)|((unsigned)header[2]<<16)|((unsigned)header[3]<<24);
    if(!left || left>1024U*1024U) finish(32);
    exact(64,3,(unsigned char *)"LIDAR_COPY_READY\n",17);
    while(left) {
        unsigned n=left<sizeof(buffer)?left:sizeof(buffer);
        exact(63,0,buffer,n);
        exact(64,1,buffer,n);
        left-=n;
        exact(64,3,(unsigned char *)"LIDAR_BLOCK_OK\n",15);
    }
    finish(0);
}
