; lc_mi_fmt4.s - findings/fpu-fixes/plan.md N1: the MC68LC040's format $4
; frame stacks the operand's CALCULATED address for a memory-indirect FP
; operand (M68040UM A.5.1, p. A-6: "the calculated effective address of the
; operand ... using the addressing mode in which the effective address is
; calculated").  An LC040 F-line emulator trusts this field; before the fix
; the core stacked the POINTER's address, the exception being taken before
; the pointer was read.
;
; What each case would catch:
;   1  ([bd]): the pointer at $3100 holds $3200 -- EA $3200, not $3100.
;   2  ([bd],od): outer displacement 4 -- EA $3204, not $3104.
;   3  ([bd,An],Xn,od), postindexed: pointer at A0 = $3108 holds $3200, plus
;      D1*2 = 2 plus od 2 -- EA $3204.
;   4  absolute short, no pointer: EA $3200 (the control).
; Each pointer is read exactly once (readonce), and the operand never.
;
; Each trap records four longwords at (a6)+, absolute: the format/vector
; word, the stacked (next) PC, the EA field and the faulted PC.
;
; diff: --cycles 40000
v_flin	equ	h_flin
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$7000,a6
	movea.l	#$3108,a0
	moveq	#1,d1
c1:	fdiv.w	([$3100.w]),fp5		; 1: EA $3200
c2:	fdiv.w	([$3104.w],4),fp5	; 2: EA $3204
c3:	fdiv.w	([0,a0],d1.l*2,2),fp5	; 3: EA $3204
c4:	fdiv.w	$3200.w,fp5		; 4: EA $3200 (control)
halt:	bra.s	halt

; format $4: the stacked PC is already the next instruction's
h_flin:	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,(a6)+		; format/vector word
	move.l	2(sp),(a6)+		; stacked PC
	move.l	8(sp),(a6)+		; EA field
	move.l	12(sp),(a6)+		; faulted PC
	rte

unexp:	bra.s	unexp

	org	$3100
	dc.l	$3200, $3200, $3200	; the three pointers
	org	$3200
	dc.w	5, 5, 5
