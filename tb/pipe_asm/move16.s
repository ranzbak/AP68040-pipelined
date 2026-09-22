; move16.s - plan M4 tb_ap040_pipe_move16: all five MOVE16 forms, lines
; aligned down to 16 whatever the low address bits, (An)+ gets +16 (not
; aligned), Ax = Ay incremented once, a stored line read back at once
; (store-to-load), the source read once.
; expect-inimage
; expect-range: 7000 7100
; expect-readonce: 7000 7004 7008 700c
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
	movea.l	#$7000,a6
	moveq	#15,d0
fill:	move.l	d0,d1
	mulu.w	#$1111,d1
	swap	d1
	move.w	d0,d1
	move.l	d1,(a6)+
	dbf	d0,fill			; $7000..$703F: 16 distinct longs
	movea.l	#$700B,a0		; line $7000
	movea.l	#$7047,a1		; line $7040
	move16	(a0)+,(a1)+
	move.l	a0,($70f0).l		; $701B
	move.l	a1,($70f4).l		; $7057
	movea.l	#$7015,a2
	move16	(a2)+,($7063).l		; line $7010 -> $7060
	move.l	a2,($70f8).l
	movea.l	#$7084,a3
	move16	($702F).l,(a3)+		; line $7020 -> $7080
	move.l	a3,($70fc).l
	movea.l	#$7030,a4
	move16	(a4),($70A0).l		; line $7030 -> $70A0
	movea.l	#$70BF,a5
	move16	($7040).l,(a5)		; the line just written -> $70B0
	movea.l	#$7064,a0
	move16	(a0)+,(a0)+		; Ax = Ay: line $7060 onto itself, a0 + 16 once
	move.l	a0,($70ec).l
halt:
	bra.s	halt
unexp:
	bra.s	unexp
