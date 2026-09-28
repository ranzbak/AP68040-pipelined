ENTRY(soc_main)
SECTIONS
{
	. = 0x41000000;
	.text : { *(.text.soc_main) *(.text .text.*) }
	.rodata : { *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
