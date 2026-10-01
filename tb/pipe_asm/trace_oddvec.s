; trace_oddvec.s - a trace whose OWN vector is odd takes the address error
; itself; the instruction after the traced one never runs.
;
; cputest's ODDEXC / ODDIRQ groups point every vector from 4 up at $123 (the
; trace vector included) and put an ILLEGAL after the test instruction.  The
; generator records the trace as a stacked frame and lets the ILLEGAL's odd
; vector 4 fault (PC field $10): it never applies the odd vector to the trace
; itself (tests/cputest/board/README.md, run2).  The 68040 takes the trace
; first, and its vector 9 is odd, so the address error belongs to the trace:
; format $2, PC field = the vector OFFSET ($24, the generator's own rule,
; cputest.cpp `regs.pc = original_exception * 4`), address = the odd
; handler address with bit 0 clear ($122), and the stacked SR is the new one
; (S set, T1/T0 clear: $2700 from $A700).  This pins what the core does.
;
; diff: --cycles 60000
v_adr	equ	h_adr
v_trace	equ	unexp
v_ill	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; address errors
	clr.l	$7004			; format/vector word
	clr.l	$7008			; PC field
	clr.l	$700C			; address field
	clr.l	$7010			; stacked SR
	clr.l	$7014			; did the ILLEGAL run? (it must not)
	lea	0,a0			; copy the table to $5000 and point 4 and 9 at $123
	lea	$5000,a1
	move.w	#255,d1
cp:	move.l	(a0)+,(a1)+
	dbra	d1,cp
	move.l	#$123,$5000+4*4
	move.l	#$123,$5000+9*4
	move.l	#$5000,d0
	movec	d0,vbr
	move.w	#$A700,sr		; T1, supervisor
	moveq	#1,d2			; traced: the trace vector is odd
	dc.w	$4AFC			; never reached
	addq.l	#1,$7014
cont:	move.w	#$2700,sr
	moveq	#0,d0
	movec	d0,vbr
	bra	halt

h_adr:
	addq.l	#1,$7000
	move.w	6(sp),$7006
	move.l	2(sp),$7008
	move.l	8(sp),$700C
	move.w	(sp),$7012
	moveq	#0,d0			; the real table again
	movec	d0,vbr
	move.w	#$2700,(sp)
	move.l	#cont,2(sp)
	rte

unexp:
	bra.s	unexp

halt:
	bra.s	halt
