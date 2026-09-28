; misplit.s - findings/catchup/plan.md: misaligned data transfers (MISPLIT
; splits them into aligned pieces: a longword at 2 mod 4 into two words,
; the rest into bytes).  Stores and loads at every misalignment, across a
; 16-byte line and a 4K page, a read-modify-write, and a byte store into a
; misaligned longword read back whole.  Hand-computed.
; diff: --cycles 20000
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
	lea	$6000,a0
; longwords at 1, 2 and 3 mod 4
	move.l	#$11223344,$6001
	move.l	#$55667788,$6006		; 2 mod 4: two words
	move.l	#$99aabbcc,$600b
	move.l	$6001,d0			; 11223344
	move.l	$6006,d1			; 55667788
	move.l	$600b,d2			; 99aabbcc
; a word at an odd address
	move.w	#$ddee,$6011
	move.w	$6011,d3			; 0000ddee
; across a 16-byte line (2 mod 4) and a 4K page ($6FFE-$7001)
	move.l	#$0f1e2d3c,$601e
	move.l	#$4b5a6978,$6ffe
	move.l	$601e,d4			; 0f1e2d3c
	move.l	$6ffe,d5			; 4b5a6978
; read-modify-write on a misaligned longword
	move.l	#$00000100,$6022
	addq.l	#1,$6022
	move.l	$6022,d6			; 00000101
; a byte store into a misaligned longword, the longword read back
	move.b	#$a5,$6008
	move.l	$6006,d7			; 5566a588
halt:	bra.s	halt

unexp:	bra.s	unexp

	org	$6000
	dcb.l	16,$eeeeeeee
	org	$6ff0
	dcb.l	8,$eeeeeeee
