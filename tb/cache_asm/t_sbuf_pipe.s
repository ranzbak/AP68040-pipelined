; t_sbuf_pipe.s - findings/storebuf/plan.md: the core's posted-store FIFO
; against the data read path (plan M14 step 3), the cache's invalidates and
; the MMU.  Runs under tb_ap040_pipe_compat.v (cache_allow_all = 1; the
; store buffer posts everything but the bench's $F1xx registers) with its
; DMA agent ($F1E4 address, $F1E6 data, $F1E8 = delay arms it).  The bench's
; tb_sb_check.v checks the store order and that no fast read overlaps a
; posted store.  Protocol: $F100 = failing check, $F102 = $600D / $BAD0.
;
;   1  stores to three cached lines fill the FIFO, then loads: of a line a
;      store is posted to (must see it), of a line nothing is posted to (the
;      read path may answer it), sizes mixed
;   7  four stores, then 0..7 ALU instructions (the last store has retired
;      into the FIFO and waits there), then a load of the last store's
;      longword: the read path must not answer it from the cache
;   2  a longword store across a line boundary (the cache owes the second
;      line's invalidate, winv), then a load of the second line, 0..7 ALU
;      instructions between: the load sees the store
;   3  the same page offset in another page: a store to $2480 is not a
;      store to $3480, and $2480 reads back new
;   4  a DMA write with its snoop landing 0..47 clocks into a burst of
;      store-then-load pairs on another line (a store invalidate a snoop
;      displaces, store_inv_lost): every load sees its store
;   5  a store posted with translation off, then MOVEC TC turning it on
;      (logical page 2 -> physical $4000): the store lands at physical
;      $2100, not $4100 -- the FIFO drains before the MOVEC
;   6  PFLUSHA and CPUSHA behind posted stores: the stores land

FAILREG	equ	$F100
DONEREG	equ	$F102
DMA_A	equ	$F1E4
DMA_D	equ	$F1E6
DMA_GO	equ	$F1E8
DMA_NS	equ	$F1EA
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

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
	clr.w	DMA_NS

; 1: loads with the FIFO busy
	lea	$2400,a2
	move.l	#$b0b0b0b0,16(a2)	; line B: never stored again
	move.l	(a2),d0
	move.l	16(a2),d0
	move.l	32(a2),d0
	move.l	48(a2),d0		; four lines cached
	move.l	#$01020304,d5
	move.w	#63,d6
.l1:	move.l	d5,32(a2)		; C
	move.l	d5,48(a2)		; D
	move.l	d5,(a2)			; A
	move.l	(a2),d0			; A: a posted store overlaps it
	move.l	16(a2),d1		; B: nothing posted
	move.l	48(a2),d2		; D
	cmp.l	d5,d0
	beq.s	.c1a
	failt	1
.c1a:	cmp.l	#$b0b0b0b0,d1
	beq.s	.c1b
	failt	11
.c1b:	cmp.l	d5,d2
	beq.s	.c1c
	failt	21
.c1c:	move.b	#$5a,1(a2)		; a byte into A's longword
	move.w	#$a5a5,34(a2)		; a word into C's
	move.l	(a2),d0
	move.l	32(a2),d2
	move.l	d5,d4
	and.l	#$ff00ffff,d4
	or.l	#$005a0000,d4
	cmp.l	d4,d0
	beq.s	.c1d
	failt	31
.c1d:	move.l	d5,d4
	move.w	#$a5a5,d4
	cmp.l	d4,d2
	beq.s	.c1e
	failt	41
.c1e:	add.l	#$01030507,d5
	dbra	d6,.l1

; 7: a load behind a store that waits in the FIFO
	lea	$2400,a2
	move.l	(a2),d0
	move.l	32(a2),d0
	move.l	48(a2),d0
	move.l	64(a2),d0		; lines A, C, D, E cached
	move.l	#$70707070,d5
	moveq	#7,d6
.l7:	lea	sh7,a4
	move.l	d6,d2
	lsl.l	#2,d2
	move.l	(a4,d2.l),a4
	jsr	(a4)			; d0 = A read back
	cmp.l	d5,d0
	beq.s	.c7
	failt	7
.c7:	add.l	#$01010101,d5
	dbra	d6,.l7

; 2: a store across a line boundary, then the second line
	lea	$2440,a3
	move.l	#$11223344,d5
	moveq	#7,d6
.l2:	move.l	(a3),d0
	move.l	16(a3),d0		; both lines cached
	lea	sh2,a4
	move.l	d6,d2
	lsl.l	#2,d2
	move.l	(a4,d2.l),a4
	jsr	(a4)			; d0 = the word at $2450 after the store
	cmp.w	d5,d0			; bytes $2450/$2451 = the store's low word
	beq.s	.c2
	failt	2
.c2:	add.l	#$01010101,d5
	dbra	d6,.l2

; 3: another page, the same offset
	move.l	#$33333333,$3480
	move.l	#$22222222,$2480
	move.l	$3480,d0
	move.l	$2480,d0		; both cached
	move.l	#$24802480,$2480
	move.l	$3480,d0
	cmp.l	#$33333333,d0
	beq.s	.c3a
	failt	3
.c3a:	move.l	$2480,d0
	cmp.l	#$24802480,d0
	beq.s	.c3b
	failt	13
.c3b:

; 4: a snoop into a burst of store-then-load pairs
	lea	$24c0,a4
	moveq	#0,d6			; the delay
.l4:	move.l	(a4),d0
	move.l	16(a4),d0		; both cached
	move.w	#$24d2,DMA_A		; the other line
	move.w	#$5555,DMA_D
	move.w	d6,DMA_GO
	move.l	d6,d5
	swap	d5
	moveq	#0,d2			; any mismatch
	rept	16
	move.l	d5,(a4)
	move.l	(a4),d0
	cmp.l	d5,d0
	sne	d1
	or.b	d1,d2
	addq.l	#1,d5
	endr
	tst.b	d2
	beq.s	.c4
	failt	4
.c4:	moveq	#50,d1
.w4:	dbra	d1,.w4
	addq.l	#1,d6
	cmp.l	#48,d6
	bne	.l4

; 5: MOVEC TC behind a posted store.  4K pages 0-15 identity except
;    logical page 2 -> physical $4000 (t_dcache_pipe's tables).
	move.l	#$0a0a0a0a,$4100
	move.l	#$0c0c0c0c,$2100
	lea	ROOT,a0
	move.l	#PTR|3,(a0)
	lea	PTR,a0
	move.l	#PAGE|3,(a0)
	lea	PAGE,a0
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.l	#1,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$4000|1,PAGE+2*4
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	pflusha
	cpusha	bc
	move.l	#$8000,d1
	move.l	#$21002100,$2100	; posted, translation off: physical $2100
	movec	d1,tc			; on: logical $2100 is physical $4100 now
	move.l	$2100,d0
	cmp.l	#$0a0a0a0a,d0		; physical $4100: untouched
	beq.s	.c5a
	failt	5
.c5a:	moveq	#0,d0
	movec	d0,tc
	pflusha
	move.l	$2100,d0
	cmp.l	#$21002100,d0
	beq.s	.c5b
	failt	15
.c5b:	move.l	$4100,d0
	cmp.l	#$0a0a0a0a,d0
	beq.s	.c5c
	failt	25
.c5c:

; 6: PFLUSHA and CPUSHA behind posted stores
	move.l	#$66666666,$2500
	move.l	#$77777777,$2510
	pflusha
	move.l	#$88888888,$2520
	cpusha	dc
	move.l	$2500,d0
	add.l	$2510,d0
	add.l	$2520,d0
	cmp.l	#$66666665,d0		; 66666666+77777777+88888888 (mod 2^32)
	beq.s	.c6
	failt	6
.c6:
	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; test 7's shapes: four stores (A last), \1 ALU instructions, the load of A
SH7	macro
	move.l	d5,32(a2)		; C
	move.l	d5,48(a2)		; D
	move.l	d5,64(a2)		; E
	move.l	d5,(a2)			; A
	rept	\1
	add.l	d3,d4
	endr
	move.l	(a2),d0
	rts
	endm
	cnop	0,4
sh7:	dc.l	k0,k1,k2,k3,k4,k5,k6,k7
k0:	SH7	0
k1:	SH7	1
k2:	SH7	2
k3:	SH7	3
k4:	SH7	4
k5:	SH7	5
k6:	SH7	6
k7:	SH7	7

; test 2's shapes: \1 ALU instructions between the line-crossing store and
; the load of the second line
SH2	macro
	move.l	d5,14(a3)		; $244E-$2451
	rept	\1
	add.l	d3,d4
	endr
	move.w	16(a3),d0		; $2450-$2451
	rts
	endm
	cnop	0,4
sh2:	dc.l	g0,g1,g2,g3,g4,g5,g6,g7
g0:	SH2	0
g1:	SH2	1
g2:	SH2	2
g3:	SH2	3
g4:	SH2	4
g5:	SH2	5
g6:	SH2	6
g7:	SH2	7
