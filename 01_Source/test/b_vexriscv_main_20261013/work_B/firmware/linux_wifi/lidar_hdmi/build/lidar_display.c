/* RAM-only AA55 receiver. Wire offsets match NAV/map_protocol.h. */
#include <stdint.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <stdlib.h>
#include <windows.h>
static long input(void *p,unsigned n) { return _read(0,p,n); }
static long output(void *p,unsigned n) { return _write(1,p,n); }
static uint32_t milliseconds(void) { return (uint32_t)GetTickCount64(); }
__attribute__((noreturn)) static void finish(int rc) { exit(rc); }
#else
static long call(long number,long fd,void *buffer,unsigned size) {
    register long a0 __asm__("a0")=fd;
    register void *a1 __asm__("a1")=buffer;
    register unsigned a2 __asm__("a2")=size;
    register long a7 __asm__("a7")=number;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1),"r"(a2),"r"(a7) : "memory");
    return a0;
}
static long input(void *p,unsigned n) { return call(63,0,p,n); }
static long output(void *p,unsigned n) { return call(64,1,p,n); }
__attribute__((noreturn)) static void finish(int rc) { call(93,rc,(void *)0,0);__builtin_unreachable(); }
static uint32_t milliseconds(void) {
    uint64_t ts[2];
    /* Linux 6.12 asm-generic unistd.h: RV32 clock_gettime64 = 403. */
    if(call(403,1,ts,0)) finish(40);
    return (uint32_t)ts[0]*1000U+(uint32_t)ts[1]/1000000U;
}
#endif

#include "map_io.h"

static void text(char **p,const char *s) { while(*s) *(*p)++=*s++; }
static void number(char **p,uint32_t n) {
    char digits[10];unsigned i=0;
    do { digits[i++]=(char)('0'+n%10);n/=10; } while(n);
    while(i) *(*p)++=digits[--i];
}
static void field(char **p,const char *key,uint32_t n) {
    text(p,",\"");text(p,key);text(p,"\":");number(p,n);
}
static void signed_field(char **p,const char *key,int n) {
    text(p,",\"");text(p,key);text(p,"\":");
    if(n<0) { text(p,"-");number(p,0U-(uint32_t)n); } else number(p,(uint32_t)n);
}
static unsigned u16(const unsigned char *p) { return p[0]|((unsigned)p[1]<<8); }
static int s16(const unsigned char *p) { unsigned n=u16(p);return n>=32768?(int)n-65536:(int)n; }
static uint32_t hash32(const unsigned char *p,unsigned n) {
    uint32_t h=2166136261U;while(n--) { h^=*p++;h*=16777619U; }return h;
}
static void send_line(char *start,char *end) {
    *end++='}';*end++='\n';
    while(start<end) {
        long n=output(start,(unsigned)(end-start));
        if(n==-4) continue;
        if(n<=0) finish(41);
        start+=n;
    }
}

struct stats { uint32_t valid,points,checksum,length,fields,discarded,other,started,window,window_frames,fps; };
static void report(struct stats *s,const char *event,const unsigned char *frame,unsigned size) {
    char line[700],*p=line;uint32_t now=milliseconds(),elapsed=now-s->window;
    if(elapsed>=1000) { s->fps=s->window_frames*1000000U/elapsed;s->window=now;s->window_frames=0; }
    text(&p,"{\"event\":\"");text(&p,event);text(&p,"\"");
    field(&p,"display_frame_id",s->valid);field(&p,"semantic_approx",1);field(&p,"semantic_refresh_mask",semantic_refresh_mask);field(&p,"seq",s->valid);field(&p,"elapsed_ms",now-s->started);field(&p,"fps_milli",s->fps);
    field(&p,"checksum_errors",s->checksum);field(&p,"length_errors",s->length);
    field(&p,"field_errors",s->fields);field(&p,"discarded_bytes",s->discarded);field(&p,"other_frames",s->other);
    if(frame) {
        field(&p,"type",2);field(&p,"bytes",size);field(&p,"rx",frame[5]);field(&p,"ry",frame[6]);
        signed_field(&p,"yaw_mrad",s16(frame+7));signed_field(&p,"vy_mm_s",s16(frame+9));
        signed_field(&p,"vx_mm_s",s16(frame+11));signed_field(&p,"wz_mrad_s",s16(frame+13));
        field(&p,"points",u16(frame+15));field(&p,"hash32",hash32(frame,size));
        signed_field(&p,"robot_x_mm",((int)frame[5]-100)*50);signed_field(&p,"robot_y_mm",((int)frame[6]-100)*50);
    }
    send_line(line,p);
}

static int run(void) {
    unsigned char buffer[1130];unsigned used=0;struct stats s;volatile uint32_t *map=map_open();
    if(!map) return 43;
    s.valid=s.points=s.checksum=s.length=s.fields=s.discarded=s.other=s.window_frames=s.fps=0;
    s.started=s.window=milliseconds();report(&s,"stream_ready",(void *)0,0);
    for(;;) {
        long got=input(buffer+used,512);unsigned pos=0;
        if(got==-4) continue;
        if(got<0) return 42;
        if(!got) break;
        used+=(unsigned)got;
        while(used-pos>=2) {
            unsigned length,total,xor=0,i,n;unsigned char *f=buffer+pos;
            if(f[0]!=0xaa || f[1]!=0x55) { pos++;s.discarded++;continue; }
            if(used-pos<4) break;
            length=u16(f+2);
            if(length<1 || length>613) { s.length++;pos++;s.discarded++;report(&s,"error",(void *)0,0);continue; }
            total=length+5;if(used-pos<total) break;
            for(i=2;i<total-1;i++) xor^=f[i];
            if(xor!=f[total-1]) { s.checksum++;pos++;s.discarded++;report(&s,"error",(void *)0,0);continue; }
            if(f[4]!=2) { s.other++;pos+=total;continue; }
            n=length>=13?u16(f+15):301;
            if(n>300 || length!=13+2*n || f[5]>200 || f[6]>200) {
                s.fields++;pos+=total;report(&s,"error",(void *)0,0);continue;
            }
            for(i=0;i<2*n;i++) if(f[17+i]>200) break;
            if(i!=2*n) { s.fields++;pos+=total;report(&s,"error",(void *)0,0);continue; }
            if(map_update(map,f,n,s.valid+1)) return 44;
            s.valid++;s.points+=n;s.window_frames++;report(&s,"frame",f,total);pos+=total;
        }
        for(unsigned i=0;i<used-pos;i++) buffer[i]=buffer[pos+i];
        used-=pos;
    }
    if(used) { s.length++;s.discarded+=used;report(&s,"error",(void *)0,0); }
    report(&s,"stream_done",(void *)0,0);
    return s.checksum || s.length || s.fields ? 1 : 0;
}

#ifdef _WIN32
int main(void) { _setmode(0,_O_BINARY);_setmode(1,_O_BINARY);return run(); }
#else
__attribute__((noreturn)) void _start(void) { finish(run()); }
#endif
