#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <fcntl.h>
#include <io.h>
#include "map_protocol_reference.h"
int main(void) {
 map_protocol_points_t p;unsigned char out[MAP_PROTOCOL_MAX_FRAME_BYTES];size_t n;
 _setmode(_fileno(stdout),_O_BINARY);memset(&p,0,sizeof p);
 p.frame_type=2;p.rx=0;p.ry=200;p.yaw_mrad=-32768;p.vy_mm_s=32767;p.vx_mm_s=-1234;p.wz_mrad_s=3210;p.n=300;
 for(unsigned i=0;i<300;i++){p.gx[i]=i%201;p.gy[i]=(200-i%201);}
 n=map_protocol_encode(&p,out,sizeof out);assert(n==618);fwrite(out,1,n,stdout);
 p.n=0;n=map_protocol_encode(&p,out,sizeof out);assert(n==18);fwrite(out,1,n,stdout);
 p.frame_type=3;n=map_protocol_encode(&p,out,sizeof out);assert(n==6);fwrite(out,1,n,stdout);
 p.frame_type=2;p.n=301;assert(!map_protocol_encode(&p,out,sizeof out));
 p.n=1;p.gx[0]=201;assert(!map_protocol_encode(&p,out,sizeof out));return 0;
}