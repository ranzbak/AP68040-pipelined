; rmw.s - plan M2 tb_ap040_pipe_rmw: read-modify-write memory destinations
; (ADD/SUB/AND/OR/EOR Dn,<ea>, ADDI/ANDI/SUBI/EORI/ORI #,<ea>, ADDQ/SUBQ,
; NEG/NEGX/NOT) at all sizes and several EA modes, and CLR, which on the
; 68040 is a pure write (it does not read its destination -- reference
; ap040_core.v CLR; the bench's noread check catches a read).
; expect-mem: m32 1200 m32 1204 m32 1208 m32 120c m32 1210 m32 1214 m32 1218 m32 121c m32 1220 m32 1224 m32 1228 m32 122c m32 1230 m32 1234 m32 1238 m32 123c m32 1300 m32 1304 m32 1308 m32 130c m32 1310 m32 1314
; expect-noread: 1300 1301 1302 1303 1304 1305 1306 1307 1308 1309 130a 130b 130c 130d
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
	movea.l	#dst,a0
	movea.l	#log,a6
	move.l	#$01010101,d0
	move.l	#$80000001,d1
	add.l	d0,(a0)			; 11223344 + 01010101
	move.w	ccr,(a6)+
	sub.w	d1,2(a0)
	move.w	ccr,(a6)+
	and.b	d0,4(a0)
	move.w	ccr,(a6)+
	moveq	#4,d2
	or.l	d1,(0,a0,d2.w*1)	; indexed RMW destination (dst+4)
	eor.w	d0,8(a0)
	move.w	ccr,(a6)+
	addi.l	#$7FFFFFFF,12(a0)
	move.w	ccr,(a6)+
	subi.b	#$81,16(a0)
	move.w	ccr,(a6)+
	andi.w	#$0F0F,18(a0)
	eori.l	#$FFFFFFFF,20(a0)
	ori.b	#$80,24(a0)
	move.w	ccr,(a6)+
	addq.l	#8,28(a0)
	subq.w	#1,32(a0)
	move.w	ccr,(a6)+
	neg.l	36(a0)
	move.w	ccr,(a6)+
	move.w	#$10,ccr		; X set
	negx.b	40(a0)
	move.w	ccr,(a6)+
	not.w	42(a0)
	move.w	ccr,(a6)+
	addq.b	#1,(a0)+		; (An)+ destination
	subq.w	#2,-(a0)		; -(An) destination (a0 back to dst)
	move.w	ccr,(a6)+
	; CLR: pure writes, B/W/L, flags N=0 Z=1 V=0 C=0, X kept
	movea.l	#clrs,a1
	move.w	#$1F,ccr
	clr.l	(a1)
	move.w	ccr,(a6)+
	clr.w	4(a1)
	clr.b	6(a1)
	clr.l	(8,a1)
	clr.w	(12,a1)
	move.w	ccr,(a6)+
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1200
dst:	dc.l	$11223344,$55667788,$99AABBCC,$DDEEFF00
	dc.l	$10203040,$50607080,$90A0B0C0,$D0E0F000
	dc.l	$0000FFFF,$FFFF0000,$00000001,$80000000
	dc.l	$12345678,$9ABCDEF0,$0F0F0F0F,$F0F0F0F0
	org	$1300
clrs:	dc.l	$FFFFFFFF,$FFFFFFFF,$FFFFFFFF,$FFFFFFFF
	dc.l	$FFFFFFFF,$FFFFFFFF
	org	$1400
log:	dcb.b	64,$00
