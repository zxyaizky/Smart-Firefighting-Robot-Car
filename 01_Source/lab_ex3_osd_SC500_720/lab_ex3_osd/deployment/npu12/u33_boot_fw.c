#include <stdint.h>

#define U33_XIP_PARAMETERS ((const uint32_t *)0x20200000u)
#define NPU_AHB_INGRESS    ((volatile uint32_t *)0x80000000u)
#define NPU_PARAMETER_WORDS (327680u / 4u)

void _start(void)
{
    uint32_t i;

    for (i = 0; i < NPU_PARAMETER_WORDS; ++i)
        NPU_AHB_INGRESS[i] = U33_XIP_PARAMETERS[i];

    __asm__ volatile ("fence iorw, iorw");
    for (;;)
        __asm__ volatile ("nop");
}
