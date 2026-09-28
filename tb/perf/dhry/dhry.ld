ENTRY(_start)
SECTIONS
{
	. = 0;
	.vectors : { *(.vectors) }
	. = 0x400;
	.text : { *(.text .text.*) }
	.rodata : { *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
