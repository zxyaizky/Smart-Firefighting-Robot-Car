#ifndef LIDAR_MAP_IO_H
#define LIDAR_MAP_IO_H
#include "map_raster.h"

static long map_syscall(long number,long v0,long v1,long v2,long v3,long v4,long v5) {
    register long a0 __asm__("a0")=v0;
    register long a1 __asm__("a1")=v1;
    register long a2 __asm__("a2")=v2;
    register long a3 __asm__("a3")=v3;
    register long a4 __asm__("a4")=v4;
    register long a5 __asm__("a5")=v5;
    register long a7 __asm__("a7")=number;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1),"r"(a2),"r"(a3),"r"(a4),"r"(a5),"r"(a7) : "memory");
    return a0;
}
static int map_error(const char *s) {
    unsigned n=0;while(s[n]) n++;
    while(n) { long got=output((void *)s,n);if(got<=0) break;s+=got;n-=(unsigned)got; }
    return 1;
}
static volatile uint32_t *map_open(void) {
    long fd=map_syscall(56,-100,(long)"/dev/mem",0x101002,0,0,0);
    long address;
    if(fd<0) {
        map_error("{\"event\":\"map_error\",\"reason\":\"new_DEVMEM_kernel_required\"}\n");return (void *)0;
    }
    /* RV32 mmap2 offset is in 4096-byte pages. Valid pointers may have bit31 set. */
    address=map_syscall(222,0,0x4000,3,1,fd,0x10000);
    map_syscall(57,fd,0,0,0,0,0);
    if((unsigned long)address>=(unsigned long)-4095) {
        map_error("{\"event\":\"map_error\",\"reason\":\"MMIO_mmap_failed\"}\n");return (void *)0;
    }
    {
        volatile uint32_t *p=(volatile uint32_t *)address;
        if(p[0]!=0x4c4d4150U || p[7]!=0x000100c9U) {
            map_error("{\"event\":\"map_error\",\"reason\":\"new_lidar_FPGA_bit_required\"}\n");return (void *)0;
        }
        return p;
    }
}
static int map_wait(volatile uint32_t *p) {
    uint32_t started=milliseconds();unsigned spins=0;
    while(!(p[1]&1U)) {
        if(++spins==1024) {
            spins=0;
            if(milliseconds()-started>1000)
                return map_error("{\"event\":\"map_error\",\"reason\":\"HDMI_frame_flip_timeout\"}\n");
        }
    }
    return 0;
}
static int map_update(volatile uint32_t *p,const unsigned char *frame,unsigned count,uint32_t id) {
    uint32_t words[2048],robot,heading;unsigned i;
    if(map_wait(p)) return 1;
    map_raster(frame,count,words,&robot,&heading);
    for(i=0;i<2048;i++) p[2048+i]=words[i];
    p[3]=robot;p[4]=heading;p[5]=id;
    __asm__ volatile("fence iorw,iorw" ::: "memory");p[2]=3;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    if(map_wait(p)) return 1;
    if(p[6]!=id) return map_error("{\"event\":\"map_error\",\"reason\":\"display_frame_id_mismatch\"}\n");
    return 0;
}
#endif
