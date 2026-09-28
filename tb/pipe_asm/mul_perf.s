; mul_perf.s - a cycle budget for register multiplies (perf work 2026-09-28).
; 64 dependent MULU.L D1,D2 and 64 MULS.W D3,D4; the .exp maxclk is the
; budget the core has been measured to meet; the products are checked.
; diff: --cycles 20000
v_flin	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"
	org	$400
start:	moveq	#1,d1
	moveq	#1,d2
	moveq	#-1,d3
	moveq	#1,d4
	nop
	rept	64
	mulu.l	d1,d2
	endr
	rept	64
	muls.w	d3,d4
	endr
	move.l	d2,$7000
	move.l	d4,$7004
halt:	bra.s	halt
unexp:	bra.s	unexp
