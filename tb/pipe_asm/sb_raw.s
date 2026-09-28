; sb_raw.s - findings/storebuf/plan.md stage 0: a load after a store sees
; the store, however many stores sit in the posted-store FIFO between them:
; every size, overlapping, misaligned across a longword, the FIFO full,
; read-modify-write chains, a store and a load in one instruction, the same
; page offset in another page.  The bus legs also check the store order
; (tb_sb_check.v).  Hand-computed expectations.
; diff: --cycles 20000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	lea	$6000,a0
; 1 the same longword, each size, back to back
	move.l	#$11223344,(a0)
	move.l	(a0),d0			; 11223344
	move.w	#$5566,(a0)
	move.l	(a0),d1			; 55663344
	move.b	#$77,3(a0)
	move.l	(a0),d2			; 55663377
; 2 a longword store, a byte load inside it
	move.l	#$a1b2c3d4,4(a0)
	moveq	#0,d3
	move.b	6(a0),d3		; 000000c3
; 3 a longword store across a longword boundary ($6009-$600C), then a
;   word load of the second longword ($600C-$600D)
	move.l	#$01020304,9(a0)
	moveq	#0,d4
	move.w	12(a0),d4		; 000004ee
; 4 five stores (more than the FIFO holds), then the first and last read back
	move.l	#$10000001,$6100
	move.l	#$10000002,$6104
	move.l	#$10000003,$6108
	move.l	#$10000004,$610c
	move.l	#$10000005,$6110
	move.l	$6100,d5
	add.l	$6110,d5		; 20000006
; 5 read-modify-write chains on one longword
	lea	$6200,a1
	addq.l	#1,(a1)
	addq.l	#1,(a1)
	addq.l	#1,(a1)			; eeeeeef1
	not.b	3(a1)			; eeeeee0e
	move.l	(a1),d6
; 6 a store and a load in one instruction, then the destination read back
	move.l	(a0),8(a1)		; $6208 = 55663377
	move.l	8(a1),d7
; 7 the same page offset in another page: $7300 is not $6300
	move.l	#$12345678,$6300
	movea.l	$7300,a2		; deadbeef
; 8 predecrement stores, a postincrement load over both
	lea	$6410,a3
	move.w	#$aaaa,-(a3)
	move.w	#$bbbb,-(a3)
	movea.l	(a3)+,a4		; bbbbaaaa
; 9 MOVEM out, then its last slot read back
	movem.l	d0-d2,$6500
	movea.l	$6508,a5		; 55663377
; 10 byte stores build a longword, read as one
	move.b	#$de,$6600
	move.b	#$ad,$6601
	move.b	#$be,$6602
	move.b	#$ef,$6603
	movea.l	$6600,a6		; deadbeef
halt:	bra.s	halt

unexp:	bra.s	unexp

	org	$6000
	dcb.l	512,$eeeeeeee
	org	$7300
	dc.l	$deadbeef
