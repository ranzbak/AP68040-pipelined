; ccr_fwd.s - plan M2 tb_ap040_pipe_ccr_fwd: every ALU operation class sets
; the CCR and is IMMEDIATELY followed by a conditional branch (and by an
; Scc and a DBcc) that depends on it -- the CCR written through from EX to
; EA-fetch's branch resolution.  Each case logs 1 (taken) or 0.
; expect-mem: m32 1400 m32 1404 m32 1408 m32 140c m32 1410 m32 1414 m32 1418 m32 141c m32 1420 m32 1424 m32 1428 m32 142c m32 1430 m32 1434 m32 1438 m32 143c m32 1440 m32 1444 m32 1448 m32 144c
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

tk	macro			; \1 = condition: log 1 if taken, 0 if not
	b\1.s	t\@
	move.b	#0,(a6)+
	bra.s	n\@
t\@:	move.b	#1,(a6)+
n\@:
	endm

	org	$400
start:
	movea.l	#log,a6
	moveq	#0,d0
	tk	eq
	moveq	#-1,d0
	tk	mi
	move.l	#$7FFFFFFF,d1
	addq.l	#1,d1
	tk	vs
	subq.l	#1,d1
	tk	vs
	add.l	d1,d1
	tk	cs
	moveq	#5,d2
	sub.l	#5,d2
	tk	eq
	cmp.l	#6,d2
	tk	lt
	cmpi.w	#0,d2
	tk	le
	and.l	#0,d1
	tk	eq
	or.b	#$80,d1
	tk	mi
	eor.w	#$FFFF,d1
	tk	pl
	not.l	d1
	tk	ne
	neg.l	d1
	tk	cs
	move.w	#$04,ccr
	moveq	#0,d3
	negx.l	d3
	tk	eq
	tst.l	d3
	tk	eq
	clr.b	d3
	tk	eq
	ext.w	d3
	tk	ge
	swap	d3
	tk	eq
	movea.l	#-1,a0
	cmpa.w	#-1,a0
	tk	eq
	move.w	#$10,ccr
	moveq	#-1,d4
	moveq	#0,d5
	addx.l	d5,d4
	tk	cs
	; Scc and DBcc straight after a flag setter
	moveq	#0,d6
	seq	(a6)+
	moveq	#1,d6
	seq	(a6)+
	moveq	#2,d7
	moveq	#0,d6
dbl:	addq.l	#1,d6
	cmp.l	#2,d6
	dbeq	d7,dbl
	move.b	d6,(a6)+
	move.b	d7,(a6)+
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1400
log:	dcb.b	80,$EE
