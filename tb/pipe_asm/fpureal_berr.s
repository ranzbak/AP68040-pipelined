; fpureal_berr.s - an access error on a floating-point MEMORY READ takes
; vector 2 (M68040UM 8.2.1) and the instruction restarts (audit 2026-09-27,
; finding 1: the fault was dropped in P_FPU and the read reissued for ever).
;
; Bus mode only: the bench rejects the FIRST read of each armed address, so
; the restart succeeds.  Each fault logs four longwords at (a6)+: the
; format/vector word, the stacked PC, the SSW, the fault address.
;
; What each case would catch:
;   1  FMOVE.X (A0)+,FP1, the second longword faults: restart, the operand
;      complete, A0 stepped by 12 ONCE.
;   2  FMOVEM.X (A1),FP2/FP3, FP3's first longword faults: both loaded.
;   3  FMOVE.L (A2),FPCR: a control-register load.
;   4  FMOVEM.L (A3),FPCR/FPSR, the second longword faults.
;   5  FRESTORE (A4) of an IDLE frame, the header faults.
;
; expect-berr: 7004 r 710c r 7180 r 7194 r 7300 r
; diff: --cycles 120000
v_flin	equ	unexp
v_fpun	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
v_berr	equ	h_berr
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$7800,a6		; fault log
c1:	lea	$7000,a0
	fmove.x	(a0)+,fp1		; 1: 3.0, $7004 faults
	fmove.l	fp1,$7200
	move.l	a0,$7204
c2:	lea	$7100,a1
	fmovem.x (a1),fp2/fp3		; 2: 5.0, 7.0, $710C faults
	fmove.l	fp2,$7208
	fmove.l	fp3,$720C
c3:	lea	$7180,a2
	fmove.l	(a2),fpcr		; 3: $00000010, $7180 faults
	fmove.l	fpcr,$7210
c4:	lea	$7190,a3
	fmovem.l (a3),fpcr/fpsr		; 4: 0 and $02000000, $7194 faults
	fmove.l	fpsr,$7214
	fmove.l	fpcr,$721C
c5:	lea	$7300,a4
	frestore (a4)			; 5: IDLE, the header faults
	fsave	$7218			; still IDLE after the restart
halt:	bra.s	halt

h_berr:	moveq	#0,d7
	move.w	6(sp),d7
	move.l	d7,(a6)+		; format/vector
	move.l	2(sp),(a6)+		; stacked PC
	moveq	#0,d7
	move.w	$0c(sp),d7
	move.l	d7,(a6)+		; SSW
	move.l	$14(sp),(a6)+		; FA
	rte
unexp:	bra.s	unexp

	org	$7000
	dc.l	$40000000,$C0000000,$00000000		; 3.0
	org	$7100
	dc.l	$40010000,$A0000000,$00000000		; 5.0
	dc.l	$40010000,$E0000000,$00000000		; 7.0
	org	$7180
	dc.l	$00000010
	org	$7190
	dc.l	$00000000,$02000000
	org	$7300
	dc.l	$41000000
