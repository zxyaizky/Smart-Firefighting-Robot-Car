/* Small userspace receiver; offsets come from NAV/map_protocol.h, not C struct layout. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define MAX_PAYLOAD 613
#define MAX_STATIC_BYTES (1024UL * 1024UL)

static unsigned u16(const unsigned char *p) { return p[0] | ((unsigned)p[1] << 8); }
static int s16(const unsigned char *p) { unsigned v=u16(p); return v>=32768 ? (int)v-65536 : (int)v; }

static int fail(const char *reason) {
    fprintf(stderr,"LIDAR_FAIL: %s\n",reason);
    return 1;
}

static int parse(FILE *file, unsigned round, unsigned long *bytes) {
    unsigned char frame[MAX_PAYLOAD+5];
    unsigned frames=0,points=0,point_frames=0;
    size_t got;
    *bytes=0;
    while ((got=fread(frame,1,4,file))!=0) {
        unsigned length,checksum=0,i,n;
        if (got!=4 || frame[0]!=0xaa || frame[1]!=0x55) return fail("header/truncated frame");
        length=u16(frame+2);
        if (length<1 || length>MAX_PAYLOAD) return fail("payload length");
        if (fread(frame+4,1,length+1,file)!=length+1) return fail("truncated payload");
        for (i=2;i<length+4;i++) checksum^=frame[i];
        if (checksum!=frame[length+4]) return fail("XOR checksum");
        if (frame[4]==2) {
            if (length<13) return fail("point metadata length");
            n=u16(frame+15);
            if (n>300 || length!=13+2*n) return fail("point count/length mismatch");
            if (frame[5]>=201 || frame[6]>=201) return fail("robot grid coordinate");
            for(i=0;i<2*n;i++) if(frame[17+i]>=201) return fail("point grid coordinate");
            printf("{\"event\":\"frame\",\"round\":%u,\"type\":2,\"bytes\":%u,\"rx\":%u,\"ry\":%u,"
                   "\"yaw_mrad\":%d,\"vy_mm_s\":%d,\"vx_mm_s\":%d,\"wz_mrad_s\":%d,\"points\":%u,"
                   "\"robot_x_mm\":%d,\"robot_y_mm\":%d}\n",
                   round,length+5,frame[5],frame[6],s16(frame+7),s16(frame+9),s16(frame+11),s16(frame+13),n,
                   ((int)frame[5]-100)*50,((int)frame[6]-100)*50);
            points+=n;point_frames++;
        } else if (frame[4]==3 && length!=1) return fail("reset frame length");
        frames++;*bytes+=length+5;
    }
    if (ferror(file) || !frames) return fail("file read/empty file");
    printf("{\"event\":\"summary\",\"round\":%u,\"bytes\":%lu,\"frames\":%u,\"point_frames\":%u,\"points\":%u,\"errors\":0}\n",
           round,*bytes,frames,point_frames,points);
    return 0;
}

static int check_file(const char *path,unsigned round,unsigned long expected) {
    FILE *file=fopen(path,"rb");unsigned long bytes=0;int rc;
    if(!file)return fail("open saved file");
    rc=parse(file,round,&bytes);fclose(file);
    if(!rc && expected && bytes!=expected)return fail("saved byte count");
    return rc;
}

static int receive_file(const char *path,unsigned long bytes,unsigned copies) {
    unsigned round;unsigned char buffer[1024];char partial[256];
    if(strlen(path)>240)return fail("file path too long");
    snprintf(partial,sizeof partial,"%s.part",path);
    for(round=1;round<=copies;round++) {
        FILE *file=fopen(partial,"wb");unsigned long left=bytes;
        if(!file)return fail("open partial file");
        while(left) {
            size_t want=left>sizeof buffer ? sizeof buffer : (size_t)left;
            size_t got=fread(buffer,1,want,stdin);
            if(got!=want || fwrite(buffer,1,got,file)!=got) {fclose(file);return fail("stdin truncated or file write");}
            left-=got;
        }
        if(fclose(file))return fail("close partial file");
        if(check_file(partial,round,bytes))return 1;
        if(rename(partial,path))return fail("rename valid file");
        file=fopen(path,"rb");if(!file)return fail("readback open");
        printf("{\"event\":\"readback\",\"round\":%u,\"bytes\":%lu}\n",round,bytes);
        left=bytes;
        while(left) {
            size_t want=left>sizeof buffer ? sizeof buffer : (size_t)left;
            size_t got=fread(buffer,1,want,file);
            if(got!=want || fwrite(buffer,1,got,stdout)!=got) {fclose(file);return fail("saved file readback");}
            left-=got;
        }
        fclose(file);putchar('\n');fflush(stdout);
        if(ferror(stdout))return fail("stdout readback");
    }
    printf("{\"event\":\"session_done\",\"copies\":%u}\n",copies);return 0;
}

int main(int argc,char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
#endif
    if(argc==3 && !strcmp(argv[1],"--file"))return check_file(argv[2],0,0);
    if(argc==5 && !strcmp(argv[1],"--receive")) {
        char *end;unsigned long bytes,copies;
        errno=0;bytes=strtoul(argv[2],&end,10);
        if(errno || *end || bytes==0 || bytes>MAX_STATIC_BYTES)return fail("byte count argument");
        errno=0;copies=strtoul(argv[3],&end,10);
        if(errno || *end || copies==0 || copies>10)return fail("copies argument");
        return receive_file(argv[4],bytes,(unsigned)copies);
    }
    return fail("usage: lidar_rx --file PATH | --receive BYTES COPIES PATH");
}
