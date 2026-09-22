; cas.s - plan M3 tb_ap040_pipe_cas: CAS.B/W/L match and mismatch (Dc
; merge by size, flags from <ea> - Dc), CAS2.W/L both-match, first and
; second mismatch (flags from the failing compare, both Dc loaded, Rn a data
; or address register), and operands forwarded from the instruction before.
; Each result: SR (word) then a register (long) to (a1)+.
; The M68040's write-back on a mismatch (M68040UM p. 7-26) rewrites the
; value read, so memory contents are the same with or without it; the
; differential W stream sees it as L lines (PLAN D6).
; expect-inimage
; expect-rbcount: 7   (CAS mismatches 3, CAS2 mismatches 4; manual count, the reference makes none)
; expect-rb: 1401 1402 1404 1408 1408 1418 1424
; expect-mem: m32 1400 m32 1404 m32 1408 m32 140c m32 1410 m32 1414 m32 1418 m32 141c
; expect-mem: m32 1500 m32 1504 m32 1508 m32 150c m32 1510 m32 1514 m32 1518 m32 151c m32 1520 m32 1524 m32 1528 m32 152c
; expect-mem: m32 1530 m32 1534 m32 1538 m32 153c m32 1540 m32 1544 m32 1548 m32 154c m32 1550 m32 1554 m32 1558 m32 155c
; expect-mem: m32 1560 m32 1564 m32 1568 m32 156c m32 1570 m32 1574 m32 1578 m32 157c
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

res	macro
	move.w	sr,(a1)+
	move.l	\1,(a1)+
	endm

	org	$400
start:
	movea.l	#out,a1
	movea.l	#dat,a0
	move.w	#$10,ccr
	; ---- CAS
	move.l	#$FFFFFF12,d0		; Dc byte $12 matches
	move.l	#$000000AB,d1
	cas.b	d0,d1,(a0)		; (a0) <- $AB
	res	d0
	move.l	#$FFFFFF00,d0
	cas.b	d0,d1,1(a0)		; mismatch: Dc.b <- $34, flags $34 - $00
	res	d0
	move.l	#$5555FFFF,d0
	move.l	#$0000BEEF,d1
	cas.w	d0,d1,2(a0)		; mismatch ($5678 - $FFFF): Dc.w <- $5678
	res	d0
	cas.w	d0,d1,2(a0)		; now matches: (2,a0) <- $BEEF
	res	d0
	move.l	4(a0),d0		; the compare register loaded just before
	move.l	#$CAFEF00D,d1
	cas.l	d0,d1,4(a0)		; match
	res	d0
	moveq	#1,d0
	cas.l	d0,d1,4(a0)		; mismatch: negative - 1
	res	d0
	lea	8(a0),a2
	move.l	(a2),d0
	cas.l	d0,d1,(a2)+		; (An)+ form
	res	d0
	; ---- CAS2
	lea	16(a0),a3		; $1410
	moveq	#24,d7			; Rn2 as a data register: $1418
	add.l	a0,d7
	move.l	(a3),d2			; Dc1
	move.l	(8,a0),d3		; Dc2 (after the CAS above: $CAFEF00D)
	move.l	#$11112222,d4		; Du1
	move.l	#$33334444,d5		; Du2
	lea	8(a0),a4
	cas2.l	d2:d3,d4:d5,(a3):(a4)	; both match
	res	d2
	move.l	(a3),d6
	res	d6
	move.l	(a4),d6
	res	d6
	moveq	#0,d2			; first compare fails: both Dc loaded
	moveq	#0,d3
	cas2.l	d2:d3,d4:d5,(a3):(a4)
	res	d2
	res	d3
	move.l	#$7FFFFFFF,d3		; second fails ($33334444 - $7FFFFFFF)
	cas2.l	d2:d3,d4:d5,(a3):(a4)
	res	d3
	move.l	#$89ABFFFF,d2		; word: first matches low word only
	move.l	#$0000A5A5,d3
	move.w	#$FFFF,(a0)		; mem1 word at $1400
	move.w	#$A5A5,(24,a0)		; mem2 word at $1418 (d7)
	move.w	#$0101,d4
	move.w	#$0202,d5
	cas2.w	d2:d3,d4:d5,(a0):(d7)	; both match, Rn2 = Dn
	res	d2
	move.w	#$1234,d3
	cas2.w	d2:d3,d4:d5,(a0):(d7)	; first matches? no: mem1 now $0101
	res	d2
	res	d3
	; CAS2 with Dc1 = Dc2 and a failed compare: the 68040 leaves memory
	; operand 2 in the register (WinUAE's 68040 order; PLAN D7)
	move.l	#$11110001,($1420).l
	move.l	#$22220002,($1424).l
	lea	($1420).l,a2
	lea	($1424).l,a3
	moveq	#0,d6			; Dc1 = Dc2 = d6: the first compare fails
	cas2.l	d6:d6,d4:d5,(a2):(a3)
	move.l	d6,($1560).l		; $22220002 (operand 2)
halt:
	bra.s	halt
unexp:
	bra.s	unexp

	org	$1400
dat:	dc.b	$12,$34,$56,$78,$9A,$BC,$DE,$F0,$0F,$1E,$2D,$3C,$4B,$5A,$69,$78
	dc.l	$DEADBEEF,$00000000,$A5A5A5A5,$5A5A5A5A
	org	$1500
out:	dcb.b	128,$EE
