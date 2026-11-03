OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0x40100000;
    .init : { KEEP(*(.init)) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    . = ALIGN(8);
    .dtb : { __dtb_start = .; KEEP(*(.board_dtb)); __dtb_end = .; }
    .data : { *(.sdata*) *(.data*) }
    . = ALIGN(4);
    .bss (NOLOAD) : { __bss_start = .; *(.sbss*) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
    __trap_frame = 0x4010ff80;
    ASSERT(. < 0x40102000, "SBI/DTB overlaps the acceptance payload")
    /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
