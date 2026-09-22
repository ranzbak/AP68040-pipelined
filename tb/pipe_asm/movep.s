; movep.s - plan M4 tb_ap040_pipe_movep: MOVEP.W/.L both directions, bytes
; at every other address high byte first, .W load replaces only the low
; word, negative displacement, odd base, a register written just before the
; store and the loaded register used at once; each byte read once.
; expect-inimage
; expect-range: 7000 7080
; expect-readonce: 7041 7043 7045 7047
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
	movea.l	#$7010,a0
	move.l	#$11223344,d0
	movep.l	d0,0(a0)		; $7010 $7012 $7014 $7016
	move.w	#$5566,d1
	movep.w	d1,-7(a0)		; $7009 $700B (odd)
	movea.l	#$7021,a1
	move.l	#$A1B2C3D4,d2
	movep.l	d2,1(a1)		; $7022..$7028
	move.l	#$00000000,($7040).l
	move.l	#$89ABCDEF,($7044).l
	movea.l	#$7040,a2
	move.l	#$FFFFFFFF,d3
	movep.l	1(a2),d3		; $7041 $7043 $7045 $7047 -> $00ABCDEF? bytes 00 00 AB EF
	move.l	d3,($7060).l
	move.l	#$12345678,d4
	movep.w	4(a2),d4		; $7044 $7046 -> low word $89CD
	move.l	d4,($7064).l
	move.l	#$7050,d5
	movea.l	d5,a3			; the base written just before
	movep.w	d4,0(a3)
	movep.l	0(a0),d6
	add.l	d6,d6			; the loaded register used at once
	move.l	d6,($7068).l
halt:
	bra.s	halt
unexp:
	bra.s	unexp
