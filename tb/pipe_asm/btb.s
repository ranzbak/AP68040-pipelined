; btb.s - findings/btb/plan.md: the branch target buffer in IF.  IF learns
; ID's taken-branch redirects and fetches a branch's target the clock after
; the branch; ID confirms or recovers.  Every case must run exactly as without
; the BTB.  A misprediction that runs a word it should not lands on ILLEGAL
; ($4AFC) and fails through unexp.  Hand-computed.
;   1  DBRA loop, 100 iterations: d1 = 100
;   2  Bcc (BNE) backward loop: d2 = 100
;   3  BRA.S, BRA.W and BRA.L in a loop, each skipping an ILLEGAL: d5 = 40
;   4  BSR/RTS chains in a loop: d6 = 60
;   5  a DBRA to itself: d0.w = $FFFF
;   6  code rewritten after CINVA: the learned BRA.S becomes a NOP, the
;      skipped MOVEQ runs: d1 = 9
;   7  overlapping instruction streams: the same word is a BRA.S on one path
;      and inside a MOVE.L #imm (b: the prediction lands inside an
;      instruction) or at the end of a MOVE.W #imm (a: on a non-branch) on
;      the other: d1 = $60021234, d2 = $6002, and path B2 runs the word the
;      BRA.S skips (a3 = 1)
;   8  a loop that patches its own BRA.S into a NOP (self-modifying code):
;      d4 = 4
;   9  a learned BRA.S rewritten WITHOUT CINVA (the bus bench has no
;      instruction cache): the stale entry's target is wrong, ID's compare
;      must catch it: d3 = 7
;  10  a loop that patches its own first instruction every pass (pass n
;      loads n): IF has fetched it from the predicted target when the store
;      lands (the second code range of the self-modifying-code check):
;      d6 = 60 + 1 + 2 + 3 + 4 = 70
; Bits 1-10 of $7000 say which cases passed ($000007fe: all).
; diff: --cycles 60000
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
	moveq	#0,d7
; 1
	moveq	#99,d0
	moveq	#0,d1
.l1:	addq.l	#1,d1
	dbra	d0,.l1
	cmp.l	#100,d1
	bne.s	.x1
	bset	#1,d7
.x1:
; 2
	moveq	#0,d2
	moveq	#50,d3
.l2:	addq.l	#2,d2
	subq.l	#1,d3
	bne.s	.l2
	cmp.l	#100,d2
	bne.s	.x2
	bset	#2,d7
.x2:
; 3
	moveq	#19,d4
	moveq	#0,d5
.l3:	bra.s	.l3a
	illegal
.l3a:	addq.l	#1,d5
	bra.w	.l3b
	illegal
.l3b:	nop
	bra.l	.l3c
	illegal
	illegal
.l3c:	addq.l	#1,d5
	dbra	d4,.l3
	cmp.l	#40,d5
	bne.s	.x3
	bset	#3,d7
.x3:
; 4
	moveq	#29,d4
	moveq	#0,d6
.l4:	bsr	s1
	dbra	d4,.l4
	cmp.l	#60,d6
	bne.s	.x4
	bset	#4,d7
.x4:
; 5
	moveq	#30,d0
.l5:	dbra	d0,.l5
	cmp.w	#$FFFF,d0
	bne.s	.x5
	bset	#5,d7
.x5:
; 6: run the RAM routine three times (IF learns its BRA.S), patch the
; BRA.S to a NOP, CINVA, run it again
	lea	code6,a0
	lea	$3000,a1
	moveq	#(code6e-code6)/2-1,d0
.c6:	move.w	(a0)+,(a1)+
	dbra	d0,.c6
	cpusha	bc
	jsr	$3000
	jsr	$3000
	jsr	$3000
	cmp.l	#1,d1
	bne.s	.x6
	move.w	#$4E71,$3002		; the BRA.S becomes a NOP
	cpusha	bc
	jsr	$3000
	cmp.l	#9,d1
	bne.s	.x6
	bset	#6,d7
.x6:
; 7: path A (the BRA.S) three times, then path B and path B2
	jsr	ovp
	jsr	ovp
	jsr	ovp
	jsr	ov
	cmp.l	#$60021234,d1
	bne.s	.x7
	suba.l	a3,a3
	jsr	ov2p
	jsr	ov2p
	jsr	ov2p
	jsr	ov2
	cmp.w	#$6002,d2
	bne.s	.x7
	cmp.l	#1,a3			; path B2 ran the ADDQ, path A2 did not
	bne.s	.x7
	bset	#7,d7
.x7:
; 8
	moveq	#4,d3
	moveq	#0,d4
.l8:	addq.l	#1,d4
	subq.l	#1,d3
	bne.s	.s8
	move.w	#$4E71,.b8		; the BRA.S below becomes a NOP
.s8:
.b8:	bra.s	.l8
	cmp.l	#4,d4
	bne.s	.x8
	bset	#8,d7
.x8:
; 9: the routine at $30F8 is reached sequentially through four NOPs, so IF
; looks up the fetch at $3100 (the BRA.S)
	lea	code9,a0
	lea	$30F8,a1
	moveq	#(code9e-code9)/2-1,d0
.c9:	move.w	(a0)+,(a1)+
	dbra	d0,.c9
	cpusha	bc
	jsr	$30F8
	jsr	$30F8
	jsr	$30F8
	cmp.l	#6,d3
	bne.s	.x9
	move.w	#$6002,$3100		; BRA.S $3104 (the RTS): no CINVA
	moveq	#7,d3
	jsr	$30F8
	cmp.l	#7,d3
	bne.s	.x9
	bset	#9,d7
.x9:
; 10
	moveq	#3,d0
.h10:	moveq	#1,d1			; pass n loads n: the ADDQ below patches it
	add.l	d1,d6
	divu.w	#1,d2			; slow (d2 unchanged): IF runs ahead, so when
	addq.b	#1,.h10+1		; the store reaches WB the four NOPs fill EX,
	nop				; EA-fetch, EA-calc and ID, and the queue holds
	nop				; the predicted DBRA and the words IF fetched
	nop				; at its target
	nop
	dbra	d0,.h10
	cmp.l	#70,d6
	bne.s	.x10
	bset	#10,d7
.x10:
	move.l	d7,$7000
halt:	bra.s	halt

s1:	addq.l	#1,d6
	bsr	s2
	rts
s2:	addq.l	#1,d6
	rts

; case 6's routine, copied to $3000
code6:	moveq	#1,d1
	bra.s	.c6s
	moveq	#9,d1
.c6s:	rts
code6e:

; case 9's routine, copied to $30F8
code9:	nop
	nop
	nop
	nop
	dc.w	$6004			; $3100: BRA.S $3106
	moveq	#5,d3			; $3102
	rts				; $3104
	moveq	#6,d3			; $3106
	rts
code9e:

; case 7.  ov is longword aligned, so a fetch at ov brings ov and ov+2 and
; the next sequential fetch is at ovp, the word path A fetched first (IF
; learned its BRA.S there).  Path B's MOVE.L #imm,d1 ends at ovp+2.
	cnop	0,4
ov:	nop
	dc.w	$223C			; MOVE.L #imm,d1 (path B)
ovp:	dc.w	$6002			; path A: BRA.S ovp+4 / path B: imm high
	dc.w	$1234			; path B: imm low / path A: skipped
	rts
	cnop	0,4
ov2:	nop
	dc.w	$343C			; MOVE.W #imm,d2 (path B2)
ov2p:	dc.w	$6002			; path A2: BRA.S ov2p+4 / path B2: imm
	addq.l	#1,a3			; path B2 / path A2: skipped
	rts

unexp:	move.l	#$BAD,$7000
.u:	bra.s	.u
