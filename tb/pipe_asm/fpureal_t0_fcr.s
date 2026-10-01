; fpureal_t0_fcr.s - T0 traces a control-register move only when it goes
; to MEMORY.  WinUAE (fpp.cpp, the FMOVE(M) Control Register(s),EA arm)
; calls trace_t0_68040 for the memory destination and not for the Dn / An
; forms; cputest on the board (tests/cputest/board, fint/FMOVEM.X) got "Got
; unexpected trace exception" after `fmove.l fpiar,d0` with T0 set.
;
; T0 is switched on by an RTE (the way cputest enters a test), in supervisor
; mode so the program keeps its stack.  Traced instructions add their address
; field to $7004 and count in $7000.
;   1  fmove.l fpiar,d0      to Dn:      no trace
;   2  fmove.l fpiar,a0      to An:      no trace
;   3  fmove.l fpcr,(a1)     to memory:  traced
;   4  fmovem.x fp0,(a2)     FP registers to memory: traced (unchanged rule)
; then MOVE to SR clears T0 (itself traced: the last one).
;
; diff: --cycles 60000
v_trace	equ	h_trace
v_flin	equ	unexp
v_fpun	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; traces
	clr.l	$7004			; sum of the traced address fields
	lea	$6000,a1
	lea	$6100,a2
	fmove.l	#$1234,fpiar
	clr.w	-(sp)			; format 0
	pea	t1
	move.w	#$6000,-(sp)		; T0, S
	rte
t1:	fmove.l	fpiar,d0		; no trace
t2:	fmove.l	fpiar,a0		; no trace
t3:	fmove.l	fpcr,(a1)		; traced
t4:	fmovem.x fp0,(a2)		; traced
t5:	move.w	#$2700,sr		; traced, clears T0
	nop
	bra.s	halt

h_trace:
	addq.l	#1,$7000
	move.l	8(sp),d6
	add.l	d6,$7004
	rte

unexp:
	bra.s	unexp

halt:
	bra.s	halt
