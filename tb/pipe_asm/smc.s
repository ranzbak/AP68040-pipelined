; smc.s - plan M4 (t_integer.s "store into the fetch queue"): a store into
; code the pipeline already holds refetches it -- the next instruction, an
; extension word of an instruction being gathered, an instruction two
; ahead, a word in the fetch queue, code after a taken branch, and the
; next instruction whose stale copy would have an effect; each
; behind a divide that keeps the queue full while the store waits.
; expect-inimage
; expect-range: 7000 7040
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
	; ---- the next instruction: nop -> addq.w #1,d7
	lea	s1(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$5247,(a0)
s1:	nop
	move.l	d7,($7000).l
	; ---- an extension word: move.l #$11111111,d1 -> #$2222....
	lea	s2+2(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$2222,(a0)
s2:	move.l	#$11111111,d1
	move.l	d1,($7004).l
	; ---- two instructions ahead
	lea	s3(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$5447,(a0)		; nop -> addq.w #2,d7
	moveq	#5,d2
s3:	nop
	move.l	d7,($7008).l
	move.l	d2,($700c).l
	; ---- four words ahead (in the queue)
	lea	s4(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$5847,(a0)		; nop -> addq.w #4,d7
	moveq	#1,d3
	moveq	#2,d3
	moveq	#3,d3
s4:	nop
	move.l	d7,($7010).l
	; ---- after a taken branch
	lea	s5(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$5047,(a0)		; nop -> addq.w #8,d7
	bra.s	s5
	moveq	#-1,d7			; skipped
s5:	nop
	move.l	d7,($7014).l
	; ---- the next instruction, whose old version has an effect: the stale
	; copy must not execute (addq.w #1,d6 -> nop; M7: the refetch now goes
	; out while the store is still held in WB)
	moveq	#0,d6
	lea	s6(pc),a0
	move.l	#100,d0
	divu.w	#3,d0
	move.w	#$4E71,(a0)
s6:	addq.w	#1,d6
	move.l	d6,($701c).l
	; ---- a store near, not into, the code: no effect (a data word)
	move.l	#$A5A5A5A5,sdat
	move.l	sdat,($7018).l
halt:
	bra.s	halt
sdat:	dc.l	0
unexp:
	bra.s	unexp
