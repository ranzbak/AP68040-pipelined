; t_fwd_pipe.s - findings/catchup/plan.md step 1: store-to-load forwarding.
; A read that a store still in WB or in the posted-store FIFO fully covers
; is answered from that store; any other overlap waits for memory.  Runs
; under tb_ap040_pipe_compat.v (cache_allow_all = 1).  Protocol: $F100 =
; failing check, $F102 = $600D / $BAD0.
;
;   1  nested BSR/RTS, 8 deep, 20 times: every RTS reads the return address
;      its BSR just pushed
;   2  a longword store, then every byte, both words and the longword of it
;      read back, 0..3 ALU instructions between (SH2 shapes)
;   3  a word store into a longword, then the longword: a partial overlap,
;      merged with memory
;   4  two stores to one longword (the younger wins); an older longword with
;      a younger byte into it (partial), then the longword; a byte into a
;      word, then the word
;   5  store A, store B, read A: the older store answers
;   7  an older longword store A, a younger overlapping store B, 0..5 ALU
;      instructions, the read: a longword B (the read sees B, never A) and
;      a word B into A's longword (a partial overlap with the youngest
;      store: the read merges, never takes A or B alone)
;   6  1-5 and 7 again with translation on (4K pages, identity except logical
;      page 2 -> physical $4000, t_dcache_pipe's tables), and a store/read
;      pair through the remapped page

FAILREG	equ	$F100
DONEREG	equ	$F102
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000
X	equ	$2600

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
	moveq	#0,d6			; pass: 0 translation off, 1 on
again:
; 1: nested calls
	moveq	#19,d5
.l1:	moveq	#0,d0
	bsr	c1
	cmp.l	#8,d0
	beq.s	.c1
	failt	1
.c1:	dbra	d5,.l1

; 2: a longword store, read back every way
	lea	X,a2
	move.l	#$a1b2c3d4,d4
	moveq	#3,d5
.l2:	lea	sh2,a4
	move.l	d5,d2
	lsl.l	#2,d2
	move.l	(a4,d2.l),a4
	jsr	(a4)			; d0 = $02ea when every read is right
	cmp.l	#$000002ea,d0
	beq.s	.c2
	failt	2
.c2:	dbra	d5,.l2

; 3: a word into a longword, the longword read
	move.l	#$11223344,X+8
	move.l	X+8,d0			; cached
	move.w	#$5566,X+10
	move.l	X+8,d0
	cmp.l	#$11225566,d0
	beq.s	.c3
	failt	3

; 4: the younger store wins; partial overlaps merge
.c3:	move.l	#$11111111,X+16
	move.l	#$22222222,X+16
	move.l	X+16,d0
	cmp.l	#$22222222,d0
	beq.s	.c4a
	failt	4
.c4a:	move.l	#$33333333,X+20
	move.b	#$44,X+21
	move.l	X+20,d0
	cmp.l	#$33443333,d0
	beq.s	.c4b
	failt	14
.c4b:	move.b	#$55,X+22
	move.w	X+22,d0
	cmp.w	#$5533,d0
	beq.s	.c4c
	failt	24

; 5: the older of two stores answers
.c4c:	move.l	#$aaaa5555,X+24
	move.l	#$5555aaaa,X+28
	move.l	X+24,d0
	cmp.l	#$aaaa5555,d0
	beq.s	.c5
	failt	5
.c5:
; 7: an older store forwardable, a younger overlapping one in flight
	moveq	#5,d5
.l7:	lea	sh7,a4
	move.l	d5,d2
	lsl.l	#2,d2
	move.l	(a4,d2.l),a4
	lea	X+32,a2
	jsr	(a4)			; d0 = the long read after A then long B, d1 = after A then word B
	cmp.l	#$bbbbbbbb,d0
	beq.s	.c7a
	failt	7
.c7a:	cmp.l	#$aaaabbbb,d1
	beq.s	.c7b
	failt	17
.c7b:	dbra	d5,.l7

	tst.b	d6
	bne	.c6b
; 6: translation on, then all of it again
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
	move.l	#$8000,d0
	movec	d0,tc
	move.l	#$7e7e7e7e,$2200	; logical page 2: physical $4200
	move.l	$2200,d0
	cmp.l	#$7e7e7e7e,d0
	beq.s	.c6a
	failt	6
.c6a:	moveq	#1,d6
	bra	again
.c6b:	moveq	#0,d0
	movec	d0,tc
	pflusha
	move.l	$4200,d0		; the remapped store landed at physical $4200
	cmp.l	#$7e7e7e7e,d0
	beq.s	.c6c
	failt	16
.c6c:
	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; case 1's call chain: each level adds 1 and calls the next
c1:	addq.l	#1,d0
	bsr.s	c2
	rts
c2:	addq.l	#1,d0
	bsr.s	c3
	rts
c3:	addq.l	#1,d0
	bsr.s	c4
	rts
c4:	addq.l	#1,d0
	bsr.s	c5
	rts
c5:	addq.l	#1,d0
	bsr.s	c6
	rts
c6:	addq.l	#1,d0
	bsr.s	c7
	rts
c7:	addq.l	#1,d0
	bsr.s	c8
	rts
c8:	addq.l	#1,d0
	rts

; case 7's shapes: \1 ALU instructions between the younger store B and
; the read, so B is in EX, WB or the FIFO when the read looks up
SH7	macro
	move.l	d3,16(a2)		; three stores fill the FIFO,
	move.l	d3,20(a2)		; so B waits in it
	move.l	d3,24(a2)
	move.l	#$aaaaaaaa,(a2)
	move.l	#$bbbbbbbb,(a2)
	rept	\1
	add.l	d3,d3
	endr
	move.l	(a2),d0
	move.l	d3,16(a2)
	move.l	d3,20(a2)
	move.l	d3,24(a2)
	move.l	#$aaaaaaaa,4(a2)
	move.w	#$bbbb,6(a2)
	rept	\1
	add.l	d3,d3
	endr
	move.l	4(a2),d1
	rts
	endm
	cnop	0,4
sh7:	dc.l	k0,k1,k2,k3,k4,k5
k0:	SH7	0
k1:	SH7	1
k2:	SH7	2
k3:	SH7	3
k4:	SH7	4
k5:	SH7	5

; case 2's shapes: store $a1b2c3d4 at X (a2), \1 ALU instructions, then
; the four bytes (summed: $a1+$b2+$c3+$d4 = $02ea), both words and the
; longword (each minus its right value: 0 when right).  d0 = $02ea.
SH2	macro
	move.l	d4,(a2)
	rept	\1
	add.l	d3,d3
	endr
	moveq	#0,d0
	moveq	#0,d1
	move.b	(a2),d1
	add.l	d1,d0
	move.b	1(a2),d1
	add.l	d1,d0
	move.b	2(a2),d1
	add.l	d1,d0
	move.b	3(a2),d1
	add.l	d1,d0
	move.w	(a2),d1
	sub.w	#$a1b2,d1
	add.l	d1,d0
	move.w	2(a2),d1
	sub.w	#$c3d4,d1
	add.l	d1,d0
	move.l	(a2),d1
	sub.l	#$a1b2c3d4,d1
	add.l	d1,d0
	rts
	endm
	cnop	0,4
sh2:	dc.l	g0,g1,g2,g3
g0:	SH2	0
g1:	SH2	1
g2:	SH2	2
g3:	SH2	3
