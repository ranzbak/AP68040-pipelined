; roto_math.s - the arithmetic of the Roots2 rotozoomer (rootsozoomer.s by
; the demo authors), run verbatim: calcoffsets (DIVS.L, LSL.L/LSR.L by a
; register count, ADDX.W rounding from the X flag), calcbplmod, the zoom
; (MULS.W, ASR.L by register, ADDX.W) and the palette crossfade (MULS.W,
; ASR.W #8, ADDX.W).  Expected values from a Python 68k model (gen.py).
; diff: --cycles 400000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"
screenh	equ	20
screenw	equ	320
rt_rowwidth equ	384
	org	$400
start:	lea	cases(pc),a4
	lea	$7000,a3
	moveq	#11,d6
.c:	move.w	(a4)+,d0
	move.w	(a4)+,d1
	move.w	(a4)+,d2
	move.l	a3,a0
	move.l	d6,-(sp)
	bsr	calcoffsets
	move.l	(sp)+,d6
	move.l	a3,a1
	lea	$400(a3),a2
	moveq	#screenh-2,d5
.m:	move.w	(a1)+,d1
	lsr.w	#6,d1
	add.w	#(screenw+63+64)/64,d1
	move.w	(a1),d0
	lsr.w	#6,d0
	sub.w	d1,d0
	asl.w	#3,d0
	move.w	d0,(a2)+
	dbf	d5,.m
	lea	64(a3),a3
	dbf	d6,.c
; zoom
	lea	zoomv(pc),a4
	lea	$7800,a3
	moveq	#7,d6
.z:	move.w	(a4)+,d0
	move.w	(a4)+,d7
	moveq	#0,d2
	moveq	#12,d3
	muls.w	d7,d0
	asr.l	d3,d0
	addx.w	d2,d0
	move.w	d0,(a3)+
	dbf	d6,.z
; palette
	lea	palv(pc),a1
	lea	$7820,a0
	moveq	#7,d7
	moveq	#0,d5
.p:	moveq	#0,d0
	moveq	#0,d1
	moveq	#0,d6
	move.b	(a1)+,d0
	move.b	(a1)+,d1
	move.b	(a1)+,d6
	move.w	d1,d2
	sub.w	d0,d2
	muls.w	d6,d2
	asr.w	#8,d2
	addx.w	d5,d2
	add.w	d2,d0
	move.w	d0,(a0)+
	dbf	d7,.p
	move.w	#$600D,$7840
halt:	bra.s	halt

calcoffsets:
	move.w	#screenh-1,d7
	ext.l	d1
	move.l	d1,d3
	beq.s	.horiz
	moveq	#14,d4
	moveq	#0,d6
	tst.l	d3
	bpl.s	.dudxpos
	neg.l	d3
	move.l	#16<<26,d5
	divs.l	d3,d5
.dudxneg:
	moveq	#0,d3
	move.w	d0,d3
	lsl.l	d4,d3
	divs.l	d1,d3
	add.l	d5,d3
	lsr.l	d4,d3
	addx.w	d6,d3
	move.w	d3,(a0)+
	add.w	d2,d0
	dbf	d7,.dudxneg
	bra.s	.out
.dudxpos:
	moveq	#0,d3
	move.w	d0,d3
	lsl.l	d4,d3
	divs.l	d1,d3
	lsr.l	d4,d3
	addx.w	d6,d3
	move.w	d3,(a0)+
	add.w	d2,d0
	dbf	d7,.dudxpos
	bra.s	.out
.horiz:	moveq	#12,d4
.hl:	move.w	d0,d1
	lsr.w	d4,d1
	mulu.w	#rt_rowwidth,d1
	move.w	d1,(a0)+
	add.w	d2,d0
	dbf	d7,.hl
.out:	rts

unexp:	move.w	#$0BAD,$7840
.u:	bra.s	.u
	even
cases:	dc.w	$0000,$0010,$0230,$1234,$0120,$FEF0,$FFF0,$FEE0,$0110,$8000,$0FF0,$0FF0,$4321,$F010,$F000,$7FF0,$0000,$0230,$0100,$0070,$0010,$ABCD,$FF90,$0B40,$2000,$7FF0,$8010,$3FFF,$8010,$0030,$0003,$0030,$FFD0,$C000,$FFF0,$1000
zoomv:	dc.w	$0FFF,$0200,$F001,$0200,$0B50,$1400,$F4B0,$1401,$0001,$7FFF,$8000,$0333,$1234,$0FED,$EDCB,$2001
palv:	dc.b	$00,$FF,$80,$FF,$00,$80,$10,$11,$FF,$80,$7F,$01,$00,$01,$7F,$37,$C9,$55,$C9,$37,$AA,$00,$00,$00
	even
