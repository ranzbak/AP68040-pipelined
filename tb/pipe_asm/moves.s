; moves.s - plan M4 tb_ap040_pipe_moves: MOVES Rn,<ea> in the DFC space and
; <ea>,Rn in the SFC space (FC checked on the request), .B/.W/.L, byte and
; word into An sign-extended, Dn merged, MOVES An,(An)+ stores the
; incremented An (PRM 6-25 note), ordinary data in supervisor (5) and user
; (1) mode, the exception frame (5), and MOVES in user mode: vector 8.
; expect-inimage
; expect-range: 7000 70a0
; expect-fc: 7000 3 7005 6 7010 5 7020 1 7030 7 7040 2 1ef8 5 7050 4
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	prv_h
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	moveq	#3,d0
	movec	d0,dfc
	moveq	#6,d0
	movec	d0,sfc
	movea.l	#$7000,a0
	move.l	#$11223344,d1
	moves.l	d1,(a0)			; FC 3
	moveq	#-1,d2
	moves.b	5(a0),d2		; SFC 6 read: d2 = $FFFFFFF1 (Dn low byte merged)
	move.l	d2,($7060).l
	move.l	#$CAFE0000,($7010).l	; FC 5
	moveq	#7,d0
	movec	d0,sfc
	move.b	#$80,($7031).l
	move.w	#$8001,($7032).l
	movea.l	#$7030,a1
	moves.b	1(a1),a2		; FC 7: a2 = $FFFFFF80
	moves.w	2(a1),a3		; a3 = $FFFF8001
	move.l	a2,($7064).l
	move.l	a3,($7068).l
	moves.l	(a1),d3
	move.l	d3,($706c).l
	moveq	#2,d0
	movec	d0,dfc
	movea.l	#$7040,a4
	moves.l	a4,(a4)+		; FC 2: stores $7044 (the incremented An)
	move.l	a4,($7070).l
	moveq	#4,d0
	movec	d0,dfc
	movea.l	#$7050,a5
	moves.w	d1,(a5)			; FC 4
	movec	sfc,d6
	movec	dfc,d7
	; ---- user mode: data is FC 1, MOVES is privileged
	move.w	#$0000,sr
	move.l	#$55667788,($7020).l	; FC 1
	moves.l	d1,(a0)			; vector 8, the handler returns in supervisor mode
	move.w	sr,($7074).l
halt:
	bra.s	halt
prv_h:
	move.w	(sp),($7080).l
	move.l	2(sp),($7084).l
	move.w	6(sp),($7088).l
	ori.w	#$2000,(sp)
	addq.l	#4,2(sp)
	rte
unexp:
	bra.s	unexp

	org	$7004
	dc.b	$88,$F1			; $7005 is only ever read (with SFC 6)
