; btfn.s - findings/loadstore/plan.md section 11 (BTFN): ID guesses a
; FORWARD conditional Bcc not taken and goes on down the fall-through
; path; EA-fetch redirects to the target when the branch is taken.  Every
; case runs both outcomes, and the wrong path of each taken branch holds
; something that must never take effect.  With BTFN = 0 (every Bcc
; guessed taken) the program must give the same results.
;
;   1  beq.b forward, not taken: the fall-through store happens
;   2  beq.b forward, taken: the skipped store (wrong path) never lands
;   3  bne.w / bne.l forward, taken and not taken
;   4  a strcmp-shaped loop: forward exit (mostly not taken), backward
;      loop branch (taken)
;   5  two forward branches back to back: the first not taken, the
;      second taken
;   6  a forward branch to a forward branch (both taken)
;   7  the condition set by the instruction right before (subq, cmp)
;   8  a taken forward branch over a BSR (the wrong path pushes the
;      return-address stack and redirects), then a real call and return
;   9  a taken forward branch over ILLEGAL and DIVU #0: no exception
;  10  a backward Bcc not taken; DBcc; a forward BSR
;  11  bcc.w with a displacement of 2 (the target is the next
;      instruction), taken and not taken
;
; diff: --cycles 60000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
v_divz	equ	unexp
	include	"vectors.inc"

	org	$400
start:	lea	$7000,a5		; results
	moveq	#0,d7			; wrong-path marker: must stay 0
	clr.l	4(a5)			; case 2's wrong-path store would land here
;------------------------------------- 1
	moveq	#1,d0
	tst.l	d0
	beq.s	.n1			; not taken
	move.l	#$11,(a5)		; 7000
.n1:
;------------------------------------- 2
	moveq	#0,d0
	tst.l	d0
	beq.s	.t2			; taken
	move.l	#$BAD2,4(a5)		; wrong path
	moveq	#1,d7
.t2:	move.l	#$22,8(a5)		; 7008
;------------------------------------- 3
	moveq	#5,d1
	cmp.l	#5,d1
	bne.w	.t3a			; not taken
	move.l	#$33,12(a5)		; 700C
.t3a:	cmp.l	#6,d1
	bne.w	.t3b			; taken
	moveq	#2,d7			; wrong path
.t3b:	cmp.l	#6,d1
	bne.l	.t3c			; taken
	moveq	#3,d7
.t3c:	cmp.l	#5,d1
	bne.l	.t3d			; not taken
	move.l	#$3333,16(a5)		; 7010
.t3d:
;------------------------------------- 4
	lea	s1(pc),a0
	lea	s2(pc),a1
	moveq	#0,d2			; iterations
.l4:	addq.l	#1,d2
	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.x4			; the exit: taken once (at the difference)
	tst.b	d0
	bne.s	.l4			; backward, taken
.x4:	move.l	d2,20(a5)		; 7014: 6 (the strings differ at the 6th byte)
;------------------------------------- 5
	moveq	#1,d0
	tst.l	d0
	beq.s	.t5a			; not taken
	bne.s	.t5b			; taken
	moveq	#4,d7
.t5a:	moveq	#5,d7
.t5b:	move.l	#$55,24(a5)		; 7018
;------------------------------------- 6
	moveq	#0,d0
	tst.l	d0
	beq.s	.t6a			; taken, to another forward branch
	moveq	#6,d7
.t6a:	beq.s	.t6b			; taken
	moveq	#7,d7
.t6b:	move.l	#$66,28(a5)		; 701C
;------------------------------------- 7
	moveq	#3,d3
.l7:	subq.l	#1,d3
	beq.s	.x7			; taken on the third pass, on subq's flags
	cmp.l	#99,d3
	beq.s	.x7b			; never taken
	bra.s	.l7
.x7b:	moveq	#8,d7
.x7:	move.l	d3,32(a5)		; 7020: 0
;------------------------------------- 8
	moveq	#0,d0
	tst.l	d0
	beq.s	.t8			; taken: the BSR below is the wrong path
	bsr.s	sub_bad
.t8:	bsr.s	sub_ok			; a real call and return
	move.l	d4,36(a5)		; 7024: $88
;------------------------------------- 9
	moveq	#0,d0
	tst.l	d0
	beq.s	.t9			; taken over ILLEGAL and DIVU #0
	illegal
	divu.w	#0,d0
	moveq	#9,d7
.t9:	move.l	#$99,40(a5)		; 7028
;------------------------------------- 10
	moveq	#1,d0
	tst.l	d0
.b10:	beq.s	.b10			; backward, not taken
	moveq	#2,d5
	moveq	#0,d6
.d10:	addq.l	#1,d6
	dbra	d5,.d10			; three passes
	bsr.w	fwd_sub			; forward BSR
	move.l	d6,44(a5)		; 702C: 3
	move.l	d4,48(a5)		; 7030: $1010
;------------------------------------- 11
	moveq	#0,d0
	tst.l	d0
	beq.w	*+4			; taken, to the next instruction
	tst.l	d0
	bne.w	*+4			; not taken
	move.l	#$1111,52(a5)		; 7034
;------------------------------------- end
	move.l	d7,56(a5)		; 7038: 0 (no wrong path took effect)
	move.l	#1,60(a5)		; 703C: reached the end
halt:	bra.s	halt

sub_bad: moveq	#10,d7
	rts
sub_ok:	move.l	#$88,d4
	rts
fwd_sub: move.l	#$1010,d4
	rts

unexp:	move.l	#$BAD,60(a5)
.u:	bra.s	.u

s1:	dc.b	"hello1",0
s2:	dc.b	"hello2",0
	even
