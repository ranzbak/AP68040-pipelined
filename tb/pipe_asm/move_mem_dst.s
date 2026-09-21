; move_mem_dst.s - MOVE to memory destinations: Dn,(An)+ ; (An)+,(An)+ ;
; the CCR a memory-destination MOVE sets (from the data moved); SMI/SEQ
; capture the flags right after each MOVE.  Plan M1 tb_ap040_pipe_move_mem_dst.
; expect-mem: m32 1200 m32 1204 m32 1208 m32 120c m32 1210 m16 1214 m8 1216
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
	movea.l	#src,a0
	movea.l	#dst,a1
	move.l	#$80000001,d0
	move.l	d0,(a1)+	; N=1 Z=0
	smi	d1		; d1.b = $FF
	move.l	(a0)+,(a1)+	; $00000000: Z=1
	seq	d2		; $FF
	move.l	(a0)+,(a1)+	; $7FFFFFFF: N=0 Z=0
	smi	d3		; $00
	move.w	(a0)+,(a1)+	; $8000 word: N=1
	smi	d4		; $FF
	move.b	(a0)+,(a1)+	; $00 byte: Z=1
	seq	d5		; $FF
	move.w	#$1234,(a1)	; #imm to memory
	move.l	(a0),4(a1)	; (An) -> (d16,An)
	move.l	#0,d6
	move.b	#$81,6(a1)	; byte into the middle of the long just written
	smi	d6
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1000
src:	dc.l	$00000000,$7FFFFFFF
	dc.w	$8000
	dc.b	$00,$C3
	dc.l	$A1B2C3D4
	org	$1200
dst:	dcb.b	32,$EE
