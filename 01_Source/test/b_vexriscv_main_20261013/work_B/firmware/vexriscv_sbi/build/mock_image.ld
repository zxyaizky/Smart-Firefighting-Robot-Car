OUTPUT_ARCH(riscv)
ENTRY(probe_start)
SECTIONS {
    . = 0x40400000;
    .init : { KEEP(*(.probe.entry)) KEEP(*(.init)) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    . = ALIGN(8);
    .dtb : { __dtb_start = .; KEEP(*(.board_dtb)); __dtb_end = .; }
    .data : { *(.sdata*) *(.data*) }
    . = ALIGN(4);
    .bss (NOLOAD) : { __bss_start = .; *(.sbss*) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
    ASSERT(. < 0x40400000+0x6000, "Probe exceeds its reserved slot")
    /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
