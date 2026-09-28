/* crt0.S - vectors and start for the Dhrystone bench program */
	.section .vectors,"ax"
	.long	0xE000
	.long	_start
	.rept	254
	.long	unexp
	.endr
	.text
	.globl	_start
_start:	jsr	main
1:	bra	1b
	.globl	cache_on
cache_on:
	move.l	#0x80008000,%d0
	.long	0x4e7b0002		/* movec d0,cacr */
	.word	0xf4f8			/* cpusha bc */
	rts
unexp:	move.w	#99,0xf100
	move.w	#0xbad0,0xf102
2:	bra	2b
