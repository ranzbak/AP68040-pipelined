; misalign.s - odd and word-offset (misaligned) word and long reads and
; writes (M68040UM 7.3, p. 7-6: the 040 splits them; the result is the same
; as an aligned access).  Plan M1 tb_ap040_pipe_misalign.
; expect-mem: m32 1200 m32 1204 m32 1208 m32 120c m32 1210 m32 1214
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
	move.l	1(a0),d0	; long at +1
	move.l	2(a0),d1	; long at +2 (word aligned)
	move.l	3(a0),d2	; long at +3
	move.w	1(a0),d3	; word at +1
	move.w	5(a0),d4	; word at +5
	movea.l	3(a0),a2	; MOVEA.L at +3
	movea.w	7(a0),a3	; MOVEA.W at +7, sign-extended
	move.l	d0,1(a1)	; long store at +1
	move.l	d1,6(a1)	; long store at +6
	move.w	d3,11(a1)	; word store at +11
	move.l	d2,13(a1)	; long store at +13
	move.w	#$BEEF,19(a1)	; word store at +19
	move.l	1(a1),d5	; read back what was written
	move.l	13(a1),d6
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1000
src:	dc.b	$10,$21,$32,$43,$54,$65,$76,$87,$98,$A9,$BA,$CB,$DC,$ED,$FE,$0F
	org	$1200
dst:	dcb.b	32,$00
