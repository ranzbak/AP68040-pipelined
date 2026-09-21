; postinc.s - (An)+ / -(An) at all sizes, A7 byte = 2, the An update
; forwarded to the next instruction and committed in WB, and the
; same-register corner cases.  Plan M1 tb_ap040_pipe_postinc.
; expect-mem: m32 1200 m32 1204 m32 1208 m32 120c m32 1210 m32 1214 m32 1218 m16 1ef8 m16 1efa m16 1efc m16 1efe
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
	move.b	(a0)+,d0	; a0 += 1
	move.w	(a0)+,d1	; a0 += 2 (odd address: misaligned word)
	move.l	(a0)+,d2	; a0 += 4
	move.l	a0,d3		; the updated a0 forwarded straight away
	move.b	-(a0),d4	; a0 -= 1
	move.w	-(a0),d5	; a0 -= 2
	move.l	-(a0),d6	; a0 -= 4 -> back to src
	move.l	a0,d7
	; stores
	move.b	d0,(a1)+
	move.w	d1,(a1)+
	move.l	d2,(a1)+
	move.l	a1,d0
	move.l	d6,-(a1)
	move.w	d5,-(a1)
	move.b	d4,-(a1)
	move.l	a1,d1
	; A7 byte steps are 2
	move.b	#$A5,-(a7)
	move.b	#$5A,-(a7)
	move.l	a7,d2
	move.b	(a7)+,d3
	move.b	(a7)+,d4
	; same register as source and destination
	movea.l	#dst+16,a2
	move.l	#$11223344,(a2)
	move.l	#$55667788,4(a2)
	move.l	(a2)+,(a2)+	; copies dst+16 -> dst+20, a2 += 8
	move.l	a2,d5
	move.w	-(a2),-(a2)	; copies dst+22 (word) -> dst+20, a2 -= 4
	move.l	a2,d6
	movea.l	#src,a3
	movea.l	(a3)+,a3	; MOVEA (An)+,An: the load wins over the increment
	movea.l	#dst+24,a4
	move.l	a4,(a4)+	; stores the value BEFORE the increment
	move.l	a4,d7
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1000
src:	dc.l	$01234567,$89ABCDEF,$FEDCBA98,$76543210
	org	$1200
dst:	dcb.b	64,$EE
