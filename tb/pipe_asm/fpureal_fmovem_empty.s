; fpureal_fmovem_empty.s - FMOVEM.X with an EMPTY register list moves
; nothing and leaves (An)+ / -(An) where they were.  cputest on the board
; (tests/cputest/board, fint/FMOVEM.X): `fmovem.x (a0),d1` with D1 = 0
; loaded FP7 from memory -- the list walk picked its first register before
; it looked at whether there was one.
;
; What each case would catch:
;   1  dynamic load, (A0): FP7 keeps 7
;   2  dynamic load, (A1)+: A1 does not move, FP6 keeps 6
;   3  dynamic store, -(A2): A2 does not move, no byte below it changes
;   4  static load with mask 0 ($F219 $D000, (A1)+): A1 does not move
;      (a zero step was the size rule, four)
;   5  static store with mask 0 ($F222 $E000, -(A2)): A2 does not move,
;      memory untouched
;
; diff: --cycles 60000
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
	lea	$6000,a0		; $AA guard over $6000-$603F
	move.l	#$AAAAAAAA,d0
	moveq	#15,d3
fill:	move.l	d0,(a0)+
	dbra	d3,fill
	fmove.l	#6,fp6
	fmove.l	#7,fp7
	moveq	#0,d1			; the empty dynamic list
	lea	$6000,a0
	lea	$6010,a1
	lea	$6030,a2
	fmovem.x (a0),d1		; 1
	fmovem.x (a1)+,d1		; 2
	fmovem.x d1,-(a2)		; 3
	dc.w	$F219,$D000		; 4: fmovem.x (a1)+,<nothing>
	dc.w	$F222,$E000		; 5: fmovem.x <nothing>,-(a2)
	fmove.l	fp7,d6
	fmove.l	fp6,d7
	bra.s	halt

unexp:
	bra.s	unexp

halt:
	bra.s	halt
