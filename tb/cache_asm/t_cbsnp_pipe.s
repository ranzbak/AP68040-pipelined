; t_cbsnp_pipe.s - a chipset snoop landing in the clock a copyback store
; makes its line dirty (findings/copyback: the merge/snoop race).
; Same memory map and tables as t_cb_pipe.s (pages 2-3 copyback, page 1
; write-through, page F the registers).  Set 0 holds $2400 (way 0) and
; $2000 (way 1); the DMA agent writes $1C00 (set 0, another line) N clocks
; after it is armed, N swept 0..79, and a copyback store to $2000 is issued
; right after the arm.  Whatever N, the store must be seen by the next read
; (fail 100+N) and must be in memory after CPUSHA (fail 200+N).
; Protocol: $F100 = failing check, $F102 = $600D.

FAILREG	equ	$F100
DONEREG	equ	$F102
PEEKA	equ	$F190
PEEKD	equ	$F192
CBMODE	equ	$F196
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000
CM_WT	equ	$00
CM_CB	equ	$20
CM_CI	equ	$40

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	bc
	lea	ROOT,a0
	move.l	#PTR|3,(a0)
	lea	PTR,a0
	move.l	#PAGE|3,(a0)
	lea	PAGE,a0
	lea	cmtab(pc),a1
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.b	(a1)+,d2
	or.l	#$19,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	pflusha
	move.l	#$8000,d0
	movec	d0,tc

	moveq	#0,d5			; N
	move.l	#$10000000,d6		; the store's value, changes per round
loop:	cpusha	dc			; clean slate: the row's pointer is 0 again
	move.l	$2400,d0		; set 0, way 0
	move.l	$2000,d0		; set 0, way 1
	move.w	#$1C00,$F1E4		; the DMA agent: $1C00 (set 0)
	move.w	#$5A5A,$F1E6
	move.w	#0,$F1EA		; with its snoop
	move.w	d5,$F1E8		; N clocks from now
	move.l	d6,$2000		; copyback store hit: the line goes dirty
	moveq	#60,d0
.w:	dbra	d0,.w			; let the DMA land
	cmp.l	$2000,d6		; the store must be visible
	beq.s	.a
	move.w	d5,d7
	add.w	#100,d7
	bra	fail_all
.a:	cpusha	dc
	move.w	#$2000,d0
	bsr	peek
	cmp.l	d1,d6			; ... and in memory after the push
	beq.s	.b
	move.w	d5,d7
	add.w	#200,d7
	bra	fail_all
.b:	addq.l	#1,d6
	addq.w	#1,d5
	cmp.w	#80,d5
	blt	loop
	move.w	#$600d,DONEREG
.h:	bra.s	.h

peek:	move.w	d0,PEEKA
	move.l	PEEKD,d1
	rts

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

cmtab:	dc.b	CM_WT,CM_WT,CM_CB,CM_CB,CM_CI,CM_WT,CM_WT,CM_WT
	dc.b	CM_CB,CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_CI

	org	$1C00
	dc.l	$C0C0C0C0
	org	$2000
	dc.l	$A0A0A0A0
	org	$2400
	dc.l	$A4A4A4A4
