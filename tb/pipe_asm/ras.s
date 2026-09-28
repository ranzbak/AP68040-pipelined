; ras.s - findings/catchup/plan.md step 2: the return-address stack.  ID
; predicts an RTS from the BSR/JSR it saw; EA-fetch checks the real
; return address and redirects when the guess is wrong.  Every case must
; return to the right place, predicted right or not.  Hand-computed.
;   1  calls nested 10 deep (more than the 8 entries): d0 counts levels
;   2  JSR (A0) and JSR abs.l
;   3  the return address changed on the stack (ADDQ.L #2,(SP)): the
;      RTS skips the word after the call (a mispredict)
;   4  a routine left with MOVE.L (SP)+,A1 / JMP (A1), so the stack keeps
;      a stale entry; then PEA/RTS (a computed jump, no call): the RTS pops
;      the stale entry, is mispredicted, and must still land right
;   5  a TRAP handler that calls a routine; RTE back
;   6  RTD and RTR returns
;   7  recursion: d5 = sum 1..12 = 78, 12 levels deep
; Bits 1-7 of $7000 say which cases passed ($000000fe: all).
; diff: --cycles 40000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	h_trap
	include	"vectors.inc"

	org	$400
start:
	moveq	#0,d7
; 1
	moveq	#0,d0
	bsr	n1
	cmp.l	#10,d0
	bne.s	.x1
	bset	#1,d7
.x1:
; 2
	moveq	#0,d1
	lea	r2,a0
	jsr	(a0)
	jsr	r2
	cmp.l	#2,d1
	bne.s	.x2
	bset	#2,d7
.x2:
; 3
	bsr	skip2
	bra.s	.x3			; skipped by the RTS
	bset	#3,d7
.x3:
; 4
	bsr	lj
	pea	.t4
	rts				; pops lj's stale entry: mispredicted
	bra.s	.x4
.t4:	move.l	#$44,d3
	bset	#4,d7
.x4:
; 5
	moveq	#0,d4
	trap	#0
	cmp.l	#$55,d4
	bne.s	.x5
	bset	#5,d7
.x5:
; 6
	pea	$1234			; a longword RTD drops
	bsr	rtd6
	bsr	rtr6
	cmp.l	#$66,d6
	bne.s	.x6
	bset	#6,d7
.x6:
; 7
	moveq	#12,d0
	moveq	#0,d5
	bsr	rsum
	cmp.l	#78,d5
	bne.s	.x7
	bset	#7,d7
.x7:
	move.l	d7,$7000
halt:	bra.s	halt

n1:	addq.l	#1,d0
	bsr.s	n2
	rts
n2:	addq.l	#1,d0
	bsr.s	n3
	rts
n3:	addq.l	#1,d0
	bsr.s	n4
	rts
n4:	addq.l	#1,d0
	bsr.s	n5
	rts
n5:	addq.l	#1,d0
	bsr.s	n6
	rts
n6:	addq.l	#1,d0
	bsr.s	n7
	rts
n7:	addq.l	#1,d0
	bsr.s	n8
	rts
n8:	addq.l	#1,d0
	bsr.s	n9
	rts
n9:	addq.l	#1,d0
	bsr.s	n10
	rts
n10:	addq.l	#1,d0
	rts

r2:	addq.l	#1,d1
	rts

skip2:	addq.l	#2,(sp)			; return past the BRA.S (one word)
	rts

lj:	move.l	(sp)+,a1		; return with a jump: the stack keeps lj's entry
	jmp	(a1)

h_trap:	bsr	r5
	rte
r5:	move.l	#$55,d4
	rts

rtd6:	moveq	#$60,d6
	rtd	#4
rtr6:	addq.l	#6,d6
	move.w	#$0000,-(sp)		; RTR pops the CCR word, then the PC
	rtr

rsum:	add.l	d0,d5			; d5 += n; n-- ; recurse while n
	subq.l	#1,d0
	beq.s	.r
	bsr.s	rsum
.r:	rts

unexp:	bra.s	unexp
