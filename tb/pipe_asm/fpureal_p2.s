; fpureal_p2.s - findings/fpu-fixes/plan.md P2 and P2b: packed stores to a
; data or address register, and a packed store through a memory-indirect EA.
;
; A packed-decimal DESTINATION is the unsupported data type on a 68040: vector
; 55, a post-instruction exception with format $3 (M68040UM 9.6.2).  The PRM
; calls Dn illegal for packed, but a real 68040 takes vector 55 with EA 0
; (WinUAE fpp.cpp put_fp_value, verified on hardware; PLAN.md D22), and the
; manual's rule 2 beats the PRM.  An ADDRESS register is illegal for every
; opclass 011 store: the plain F-line, format $0, the instruction's own PC
; (WinUAE put_fp_value2; opclass 011 has no opmode, so bits 6:0 are the
; k-factor and must not choose the frame -- P2b).
;
; What each case would catch:
;   1  FMOVE.P FP0,D0{#0}, static k-factor: vector 55, not format $4.
;   2  FMOVE.P FP0,D0{D1}, dynamic k-factor: vector 55, not the F-line.
;   3  FMOVE.P FP0,A0{D1}: F-line $002C -- k-factor bits $10 read as an
;      opmode give format $2.
;   4  FMOVE.P FP0,A0{#5}: the same with a static k-factor.
;   5  FMOVE.P FP0,([$3120.w]){#0}: vector 55 with the FINAL address in the
;      frame's EA field, the pointer read once (P1 through the datatype path).
;   6  FMOVE.L FP0,(d16,PC): a PC-relative DESTINATION is illegal for every
;      store -- the plain F-line, own PC, nothing written.
;   7  FMOVE.L FP0,([bd,PC]): the same through a memory-indirect PC mode --
;      and the pointer is never read (P1 must not let it through).
;
; Each trap records four longwords at (a5)+: the format/vector word, the
; stacked PC, the EA field, and the first longword of an FSAVE taken in the
; handler (the $4160 BUSY frame the FPSP reads).  The F-line handler records
; zero for the last two -- format $0 has no EA field.  Vector 55 returns by RTE
; (format $3 stacks the next PC); the F-line handler resumes at A6.
;
; diff: --cycles 120000
v_flin	equ	h_flin
v_fpun	equ	h_fpun
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	moveq	#0,d1
	fmove.l	#1,fp0
	lea	$7010,a5		; where the recorded longwords go
	lea	$5100,a4		; the handler's FSAVE area
	lea	r1,a6			; each case names where the F-line handler resumes
c1:	dc.w	$F200,$6C00		; 1: FMOVE.P FP0,D0{#0}
r1:	lea	r2,a6
c2:	dc.w	$F200,$7C10		; 2: FMOVE.P FP0,D0{D1}
r2:	lea	r3,a6
c3:	dc.w	$F208,$7C10		; 3: FMOVE.P FP0,A0{D1}
r3:	lea	r4,a6
c4:	dc.w	$F208,$6C05		; 4: FMOVE.P FP0,A0{#5}
r4:	lea	r5,a6
c5:	fmove.p	fp0,([$3120.w]){#0}	; 5: through the pointer at $3120
r5:	lea	r6,a6
c6:	dc.w	$F23A,$6000,(sent+4)-(c6+4)	; 6: FMOVE.L FP0,(d16,PC)
r6:	lea	halt,a6
c7:	dc.w	$F23B,$6000,$0161,sentp-(c7+4)	; 7: FMOVE.L FP0,([bd,PC])
halt:	bra.s	halt

; vector 55, format $3: the stacked PC is already the next instruction's
h_fpun:	moveq	#0,d2
	move.w	6(sp),d2
	move.l	d2,(a5)+		; format/vector word
	move.l	2(sp),(a5)+		; stacked PC
	move.l	8(sp),(a5)+		; EA field
	fsave	(a4)
	move.l	(a4),(a5)+		; the state frame's header
	clr.l	-(sp)			; leave the unit as FRESTORE of NULL does
	frestore (sp)+
	rte

; vector 11: record, then resume at the case's A6 with the stack reset rather
; than RTE -- a wrong frame (format $4 or $2 before the fix) would otherwise
; take the format error and hide the cases behind it
h_flin:	moveq	#0,d2
	move.w	6(sp),d2
	move.l	d2,(a5)+
	move.l	2(sp),(a5)+
	clr.l	(a5)+
	clr.l	(a5)+
	movea.l	#$1F00,sp
	jmp	(a6)

unexp:	bra.s	unexp

	org	$3120
	dc.l	$3800			; case 5's pointer
	org	$3800
	dcb.l	3,$DEADBEEF		; case 5 must not write its operand
	org	$3900
sent:	dcb.l	4,$DEADBEEF		; case 6's target: must stay unwritten
	org	$3A00
sentp:	dcb.l	4,$00003900		; case 7's pointer: must not be read
