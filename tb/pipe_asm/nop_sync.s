; nop_sync.s - plan M5 tb_ap040_pipe_nop_sync: NOP waits until every older
; store is in memory (M68040UM 7.7 bus synchronisation, p. 7-43).  Four
; stores fill the posted-store buffer, the NOP at nsync must not retire
; before they have drained (checked in bus mode: syncpc).
; expect-inimage
; expect-syncpc: 41e
; expect-mem: m32 7000 m32 7004 m32 7008 m32 700c m32 7010
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
	movea.l	#$7000,a0
	move.l	#$11111111,(a0)+
	move.l	#$22222222,(a0)+
	move.l	#$33333333,(a0)+
	move.l	#$44444444,(a0)+
nsync:	nop
	move.l	a0,(a0)
halt:
	bra.s	halt
unexp:
	bra.s	unexp
