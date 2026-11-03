/* SPDX-License-Identifier: MIT
 * B-board port of SpinalHDL/VexRiscv src/main/c/emulator; see upstream/LICENSE.
 */
#ifndef B_PLATFORM_H
#define B_PLATFORM_H
#include <stdint.h>
#include "riscv.h"
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define UART 0xf0001100u
#define MSIP 0xf0010000u
#define TIMECMP 0xf0014000u
#define TIME 0xf001bff8u
#define TEST_RESULT 0xf0001020u
#define NEXT_ENTRY_PROBE 0x40102000u
#define NEXT_ENTRY_LINUX 0x40400000u
extern uint32_t __trap_frame[],__dtb_start[];
extern void trapEntry(void);
void putC(char c);
int32_t getC(void);
void putString(const char *s);
int read_previous_word(uint32_t address,uint32_t *word,uint32_t *cause,uint32_t *tval);
#endif
