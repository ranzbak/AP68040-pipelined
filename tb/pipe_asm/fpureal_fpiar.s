; fpureal_fpiar.s - which floating-point instructions load FPIAR with their
; own address on the 68040 (WinUAE fpp.cpp fpuop_arithmetic, the model the
; cputest corpus was generated from; cputest on the board, tests/cputest/
; board: 392 instructions "FPIAR: expected <PC> but register was not
; modified").
;
; Opclass 000/010 loads FPIAR as soon as the opmode is known to exist,
; BEFORE the effective address is looked at, so an encoding whose EA the
; 68040 rejects (an address register, an extended operand in a data
; register) still loads it and then takes the F-line.  An opmode that does
; not exist is rejected first and leaves FPIAR alone, and so do a rejected
; opclass 011 store (FPIAR is set after the store), the control-register
; moves, and the conditionals (only the 68060 sets it for those).
;
; FPIAR is set to a sentinel before every case; the F-line handler, or the
; code after the instruction, stores FPIAR to the next slot at $7000.
;   1  fadd.l a0,fp1   (An source: F-line)           -> its own PC
;   2  fabs.x d0,fp1   (extended in Dn: F-line)       -> its own PC
;   3  fadd.l d0,fp1   (legal)                        -> its own PC
;   4  fmove.l fp1,a0  (opclass 011 to An: F-line)    -> the sentinel
;   5  opmode $2B, fp0,fp0 (does not exist: F-line)   -> the sentinel
;   6  fmove.l #0,fpcr (control register)             -> the sentinel
;   7  fbeq (taken or not)                            -> the sentinel
;   8  fseq d1                                        -> the sentinel
; $7020 counts F-line exceptions (four: cases 1, 2, 4, 5).
;
; diff: --cycles 60000
v_flin	equ	h_fline
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
	lea	$7000,a5		; FPIAR slots
	clr.l	$7020
	moveq	#3,d0
	fmove.l	#1,fp1

	fmove.l	#$5A5A0001,fpiar
c1:	dc.w	$F208,$40A2		; fadd.l a0,fp1
	fmove.l	#$5A5A0002,fpiar
c2:	dc.w	$F200,$4898		; fabs.x d0,fp1
	fmove.l	#$5A5A0003,fpiar
c3:	fadd.l	d0,fp1
	fmove.l	fpiar,(a5)+
	fmove.l	#$5A5A0004,fpiar
c4:	dc.w	$F208,$6080		; fmove.l fp1,a0
	fmove.l	#$5A5A0005,fpiar
c5:	dc.w	$F200,$002B		; opmode $2B, fp0,fp0
	fmove.l	#$5A5A0006,fpiar
c6:	fmove.l	#0,fpcr
	fmove.l	fpiar,(a5)+
	fmove.l	#$5A5A0007,fpiar
c7:	fbeq	c7n
c7n:	fmove.l	fpiar,(a5)+
	fmove.l	#$5A5A0008,fpiar
c8:	fseq	d1
	fmove.l	fpiar,(a5)+
	bra.s	halt

; F-line: record FPIAR, step over the 4-byte instruction (format $0: the
; stacked PC is the instruction's own)
h_fline:
	addq.l	#1,$7020
	fmove.l	fpiar,(a5)+
	addq.l	#4,2(sp)
	rte

unexp:
	bra.s	unexp

halt:
	bra.s	halt
