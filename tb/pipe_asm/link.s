; link.s - plan M2 tb_ap040_pipe_link: LINK.W/.L (incl. A7 as the frame
; register), UNLK (incl. A7), LEA, PEA, RTD #d, RTR (restores the CCR only,
; SR's supervisor byte untouched), EXG of all three kinds.
; expect-mem: m32 1ee0 m32 1ee4 m32 1ee8 m32 1eec m32 1ef0 m32 1ef4 m32 1ef8 m32 1efc m32 1400 m32 1404 m32 1408 m32 140c m32 1410 m32 1414 m32 1418 m32 141c
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
	movea.l	#log,a5
	movea.l	#$11111111,a6
	link	a6,#-8			; push a6, a6 = sp, sp -= 8
	move.l	a6,(a5)+
	move.l	a7,(a5)+
	unlk	a6
	move.l	a6,(a5)+
	move.l	a7,(a5)+
	link.l	a6,#-$20
	move.l	a7,(a5)+
	unlk	a6
	link	a7,#-4			; LINK A7: the value pushed is the decremented SP
	move.l	a7,(a5)+
	move.l	4(a7),(a5)+
	addq.l	#8,a7
	; UNLK A7: A7 <- (A7)
	move.l	#$00001EF0,-(a7)
	unlk	a7
	move.l	a7,(a5)+
	movea.l	#$1F00,a7
	; LEA / PEA
	lea	($1234).w,a0
	lea	8(a0),a1
	lea	(4,a1,d0.w),a2
	pea	(a2)
	move.l	(a7)+,d7
	; RTD #4
	move.l	#$DEADBEEF,-(a7)	; junk the callee discards
	bsr.s	subrtd
	move.l	a7,(a5)+
	; RTR: CCR from the stack, SR supervisor byte kept
	move.l	#after,-(a7)
	move.w	#$001F,-(a7)
	rtr
after:
	move.w	sr,(a5)+
	move.w	#0,(a5)+
	move.l	a7,(a5)+
	; EXG
	moveq	#1,d0
	moveq	#2,d1
	exg	d0,d1
	movea.l	#$A0A0A0A0,a3
	movea.l	#$B0B0B0B0,a4
	exg	a3,a4
	exg	d0,a3
halt:
	bra.s	halt
subrtd:
	rtd	#4
unexp:
	bra.s	unexp

	org	$1400
log:	dcb.b	64,$00
