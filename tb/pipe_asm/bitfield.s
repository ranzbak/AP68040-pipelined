; bitfield.s - plan M3 tb_ap040_pipe_bitfield: BFTST BFEXTU BFCHG BFEXTS
; BFCLR BFFFO BFSET BFINS, register fields (offset mod 32, wrapping past
; bit 0), memory fields of every span (1-5 bytes), static and Dn offset
; (negative, beyond 32) and width (0 = 32), flags (N Z, V C cleared, X
; kept), and the forwarding of an offset/width register written just before.
; Each result: SR (word) then the register (long) to (a1)+.
; expect-inimage (every data access inside the 64K image)
; expect-mem: m32 1400 m32 1404 m32 1408 m32 140c m32 1420 m32 1424 m32 1428 m32 142c m32 1430 m32 1434 m32 1438 m32 143c
; expect-mem: m32 1500 m32 1504 m32 1508 m32 150c m32 1510 m32 1514 m32 1518 m32 151c m32 1520 m32 1524 m32 1528 m32 152c
; expect-mem: m32 1530 m32 1534 m32 1538 m32 153c m32 1540 m32 1544 m32 1548 m32 154c m32 1550 m32 1554 m32 1558 m32 155c
; expect-mem: m32 1560 m32 1564 m32 1568 m32 156c m32 1570 m32 1574 m32 1578 m32 157c m32 1580 m32 1584 m32 1588 m32 158c
; expect-mem: m32 1590 m32 1594 m32 1598 m32 159c m32 15a0 m32 15a4 m32 15a8 m32 15ac m32 15b0 m32 15b4 m32 15b8 m32 15bc
; expect-mem: m32 15c0 m32 15c4 m32 15c8 m32 15cc m32 15d0 m32 15d4 m32 15d8 m32 15dc m32 15e0 m32 15e4 m32 15e8 m32 15ec
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

res	macro
	move.w	sr,(a1)+		; first: the MOVE sets flags
	move.l	\1,(a1)+
	endm

	org	$400
start:
	movea.l	#out,a1
	movea.l	#dat,a0
	movea.l	#mod,a2
	move.l	#$12345678,d0
	moveq	#0,d2
	; ---- register fields
	move.w	#$13,ccr		; X kept, V C cleared
	bfextu	d0{4:8},d1
	res	d1
	bfexts	d0{28:8},d1		; wraps: $8 then $1 -> $81, negative
	res	d1
	bftst	d0{0:0}			; width 0 = 32
	res	d0
	bfffo	d0{8:16},d1
	res	d1
	bfffo	d2{3:5},d1		; none set: offset + width, Z
	res	d1
	move.l	d0,d3
	bfchg	d3{30:4}		; wraps
	res	d3
	bfclr	d3{0:12}
	res	d3
	bfset	d3{20:12}
	res	d3
	moveq	#-3,d5			; register field: offset mod 32 = 29
	moveq	#0,d6			; width 0 = 32
	move.l	#$89ABCDEF,d4
	bfins	d4,d3{d5:d6}
	res	d3
	moveq	#-1,d4
	bfins	d4,d3{12:1}		; N from the inserted value
	res	d3
	moveq	#0,d4
	bfins	d4,d3{12:7}		; Z from the inserted value
	res	d3
	; ---- memory fields, every span
	bfextu	(a0){0:8},d1		; 1 byte
	res	d1
	bfextu	1(a0){5:8},d1		; 2
	res	d1
	bfextu	(a0){3:18},d1		; 3
	res	d1
	bfexts	2(a0){7:25},d1		; 4
	res	d1
	bfextu	3(a0){7:32},d1		; 5
	res	d1
	bftst	5(a0){6:31}		; 5
	res	d0
	move.l	#-13,d5			; 8 - 2 bytes, bit 3
	bfexts	8(a0){d5:12},d1
	res	d1
	moveq	#100,d5			; +12 bytes, bit 4
	bfextu	(a0){d5:12},d1
	res	d1
	moveq	#11,d6
	moveq	#5,d5			; the offset register written just before
	bfextu	(a0){d5:d6},d1
	add.l	d1,d2			; the result used at once
	res	d2
	moveq	#13,d6			; the width register written just before
	bfextu	d0{3:d6},d1		; (a register field: no read to wait for)
	res	d1
	bfffo	4(a0){2:20},d1
	res	d1
	bfffo	zero(pc){5:30},d1	; none set
	res	d1
	moveq	#6,d7
	bfextu	-2(a0,d7.w){4:12},d1	; indexed
	res	d1
	bfextu	(dat+9).w{1:14},d1	; absolute
	res	d1
	; ---- memory modifications
	bfchg	(a2){2:5}		; 1 byte
	res	d0
	bfclr	1(a2){3:16}		; 3: word + byte
	res	d0
	bfset	4(a2){7:32}		; 5: long + byte
	res	d0
	move.l	#$A5A5A5A5,d4
	bfins	d4,9(a2){0:32}		; 4
	res	d4
	move.l	#$0000ABCD,d4
	bfins	d4,14(a2){4:12}		; 2
	res	d4
	move.l	#-37,d5			; 20 - 5 bytes = 15, bit 3
	moveq	#9,d6
	moveq	#-1,d4
	bfins	d4,20(a2){d5:d6}	; 2
	res	d4
	bfchg	24(a2){6:19}		; 4 (6+19 = 25 bits)
	res	d0
	bfset	27(a2){1:23}		; 3
	res	d0
	bftst	(a2){0:32}
	res	d0
	bfextu	27(a2){0:32},d1		; read back what was stored
	res	d1
halt:
	bra.s	halt
unexp:
	bra.s	unexp

zero:	dc.l	0,0

	org	$1400
dat:	dc.b	$12,$34,$56,$78,$9A,$BC,$DE,$F0,$0F,$1E,$2D,$3C,$4B,$5A,$69,$78
	org	$1420
mod:	dc.b	$12,$34,$56,$78,$9A,$BC,$DE,$F0,$0F,$1E,$2D,$3C,$4B,$5A,$69,$78
	dc.b	$C3,$3C,$A5,$5A,$96,$69,$0F,$F0,$E1,$1E,$D2,$2D,$B4,$4B,$87,$78
	org	$1500
out:	dcb.b	240,$EE
