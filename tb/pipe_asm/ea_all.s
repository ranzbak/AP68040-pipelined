; ea_all.s - plan M1 tb_ap040_pipe_ea_all: one MOVE per EA mode (all 18,
; brief and full extension words, memory indirect pre/postindexed, PC
; relative, abs.W sign extension, #imm), three sizes, loads and stores.
; The same program runs differentially as tests/asm/diff_ea.s.
; expect-mem: m32 1300 m32 1304 m32 1308 m32 130c m32 1310 m32 1314 m32 1318 m32 131c m32 1320 m32 1324 m32 1328 m32 132c m32 1330 m32 1334 m32 1338 m32 133c m32 1340 m32 1344 m32 1348 m32 134c m32 1350 m32 1354 m32 1358 m32 135c m32 1360 m32 1364
; expect-mem: m32 1200 m32 1204 m32 1208 m32 120c m32 1210 m32 1214 m32 1218 m32 121c m32 1220 m32 1224 m32 1228 m32 122c m32 1230 m32 1234 m32 1238 m32 123c m32 1240 m32 1244 m32 1248 m32 124c m32 1250 m32 1ef8 m32 1efc

	org	0
	dc.l	$1F00		; ISP
	dc.l	start
	rept	30
	dc.l	unexp		; vectors 2-31
	endr
	dc.l	trap0h		; vector 32 (TRAP #0)
	rept	223
	dc.l	unexp
	endr

	org	$400
start:
	movea.l	#data,a0
	movea.l	#dst,a1
	movea.w	#$8000,a2	; MOVEA.W sign-extends: a2 = $FFFF8000
	movea.l	#ptrs,a3
	moveq	#4,d7		; index
	moveq	#-4,d6		; negative index (word -4 = $FFFC)
	movea.l	#log,a6
; ---- source modes, long
	move.l	d7,d0		; Dn
	move.l	d0,(a6)+	; log it
	move.l	a0,d1		; An
	move.l	d1,(a6)+	; log it
	move.l	(a0),d2		; (An)
	move.l	d2,(a6)+	; log it
	move.l	(a0)+,d3	; (An)+   a0 += 4
	move.l	d3,(a6)+	; log it
	move.l	-(a0),d4	; -(An)   a0 -= 4
	move.l	d4,(a6)+	; log it
	move.l	8(a0),d5	; (d16,An)
	move.l	d5,(a6)+	; log it
	move.l	4(a0,d7.w),d0	; (d8,An,Xn.W)
	move.l	d0,(a6)+	; log it
	move.l	8(a0,d6.w),d1	; negative index, word sign-extended
	move.l	d1,(a6)+	; log it
	move.l	0(a0,d7.l*2),d2	; scale 2
	move.l	d2,(a6)+	; log it
	move.l	0(a0,d7.l*4),d3	; scale 4
	move.l	d3,(a6)+	; log it
	move.l	(data).w,d4	; abs.W
	move.l	d4,(a6)+	; log it
	move.l	(data+12).l,d5	; abs.L
	move.l	d5,(a6)+	; log it
	move.l	tbl(pc),d0	; (d16,PC)
	move.l	d0,(a6)+	; log it
	move.l	tbl(pc,d7.w),d1	; (d8,PC,Xn)
	move.l	d1,(a6)+	; log it
	move.l	#$12345678,d2	; #imm
	move.l	d2,(a6)+	; log it
	move.l	(16,a0,d7.l*2),d3	; full format, word bd
	move.l	d3,(a6)+	; log it
	move.l	($10000,a0,d7.l),d4	; full format, long bd (wraps in the 64K mirror)
	move.l	d4,(a6)+	; log it
	move.l	([a3]),d5		; memory indirect, no index, no od
	move.l	d5,(a6)+	; log it
	move.l	([a3],8),d0		; ... word od
	move.l	d0,(a6)+	; log it
	move.l	([4,a3],d7.w*2,4),d1	; postindexed
	move.l	d1,(a6)+	; log it
	move.l	([0,a3,d7.l],4),d2	; preindexed
	move.l	d2,(a6)+	; log it
	move.l	([ptrs.l],4),d3		; base suppressed, long bd
	move.l	d3,(a6)+	; log it
	move.l	(tbl2,pc,d7.l*2),d4	; full format PC-relative
	move.l	d4,(a6)+	; log it
	move.l	([pptr,pc],8),d5	; memory indirect PC-relative
	move.l	d5,(a6)+	; log it
; ---- word and byte, into Dn (merge) and An (sign extension)
	moveq	#-1,d0
	moveq	#-1,d1
	move.w	(a0),d0		; low word replaced, CCR from the word
	move.b	3(a0),d1	; low byte replaced
	movea.w	6(a0),a4	; sign-extended ($8765 -> $FFFF8765)
	movea.l	4(a0),a5
	move.w	#$ABCD,d2
	move.b	#$7F,d3
; ---- destination modes
	move.l	d7,(a1)		; (An)
	move.l	d5,(a1)+	; (An)+
	move.w	d4,(a1)+
	move.b	d3,(a1)+
	move.b	d2,-(a1)	; -(An) byte
	move.l	d1,-(a1)
	move.l	d0,8(a1)	; (d16,An)
	move.l	d6,16(a1,d7.w)	; (d8,An,Xn)
	move.w	d5,(dst+32).w	; abs.W
	move.l	d4,(dst+36).l	; abs.L
	move.l	d3,(20,a1,d7.l*4)	; full format
	move.l	d2,([a3],$40)	; memory indirect destination
	move.l	(a0),(a1)	; memory to memory
	move.l	(a0)+,(a1)+	; both post-increment
	move.w	-(a0),-(a1)	; both pre-decrement
	move.l	#$CAFEF00D,(dst+48).l
	move.l	d0,(-16).w	; abs.W negative: $FFFFFFF0
; ---- A7 byte steps by 2
	move.b	d0,-(a7)
	move.b	d1,-(a7)
	move.b	(a7)+,d2
	move.b	(a7)+,d3
; ---- odd (misaligned) word and long
	move.l	1(a0),d4
	move.w	3(a0),d5
	move.l	d4,(dst+65).l
	move.w	d5,(dst+71).l
; ---- CCR from MOVE: a negative word, a zero byte
	move.w	#$8000,d6
	move.b	#0,d7
	trap	#0		; an exception frame on the X stream (vector 32)
halt:
	bra.s	halt

trap0h:
	rte

unexp:
	bra.s	unexp

	cnop	0,4
tbl:	dc.l	$11111111,$22222222,$33333333
tbl2:	dc.l	$44444444,$55555555,$66666666,$77777777
pptr:	dc.l	data+4

	org	$1000
data:	dc.l	$01020304,$87654321,$0A0B0C0D,$DEADBEEF
	dc.l	$10203040,$50607080,$90A0B0C0,$D0E0F000
	dc.l	$F00DFACE,$C001D00D,$12121212,$34343434

	org	$1100
ptrs:	dc.l	data+8,data+32,data,data+24,data+4	; not arithmetic: pre- and postindexed must differ

	org	$1200
dst:	dcb.b	128,$EE

	org	$1300
log:	dcb.b	128,$00
