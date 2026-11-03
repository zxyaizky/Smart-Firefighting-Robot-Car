/* SPDX-License-Identifier: MIT; adapted from upstream/src/hal.c. */
#include "platform.h"
void putC(char c) {
    while(REG32(UART+4)) {}
    REG32(UART)=(uint8_t)c;
}
void putString(const char *s) { while(*s)putC(*s++); }
int32_t getC(void) {
    if(REG32(UART+8))return -1;
    uint32_t c=REG32(UART)&255u;
    /* Our FIFO is peek then pop; popping before reading loses the first byte. */
    REG32(UART+0x10)=2;
    return (int32_t)c;
}
