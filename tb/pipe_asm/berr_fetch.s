; berr_fetch.s - plan M6 tb_ap040_pipe_berr_fetch: a physical bus error on
; an instruction fetch (bus mode) -- raised only when the instruction is
; reached: vector 2, format $7, stacked PC = the instruction, SSW RW = 1,
; TM = 6 (supervisor program), SIZE of the fetch (long 00 / word 10),
; FA = EA = the fetch address; the RTE restarts and the fetch succeeds.
; A fault on a prefetch past a taken branch is never raised.  Frames go to
; the log; the .exp is the bus-mode one, checked by hand.
; expect-berr: 600 f 612 f 630 f 650 f 654 f
v_berr	equ	h_berr
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
	movea.l	#$7800,a6	; frame log
	moveq	#0,d7
	jsr	$600		; the routine's first fetch faults once
	move.l	d7,($7200).l
	jmp	$60e		; ext word of the instruction at $60e is in the faulting fetch at $612
back:
	move.l	d6,($7204).l
	jmp	$62c		; a taken branch whose fall-through fetch ($630) faults: not raised
back2:
	jmp	$64e		; two faulting fetches in a row: FA is the first one the instruction needs
back3:
	move.l	d5,($720c).l
	move.l	a6,($7208).l	; log end: 3 frames
halt:
	bra.s	halt

h_berr:
	movem.l	d0/a0,-(a7)
	lea	8(a7),a0
	moveq	#14,d0
.cp:	move.l	(a0)+,(a6)+
	dbf	d0,.cp
	movem.l	(a7)+,d0/a0
	rte
unexp:
	bra.s	unexp

	org	$600
	addq.l	#1,d7
	rts
	org	$60e
	move.l	#$12345678,d6	; opcode at $60e, immediate at $610-$613
	jmp	back
	org	$62c
	nop
	bra.s	*+$0e		; (at $62e) to $63c; $630-$63b fall through (prefetched, never run)
	nop
	nop
	org	$63c
	jmp	back2
	org	$64e
	move.l	#$9ABCDEF0,d5	; opcode at $64e, immediate at $650 (faults), then $654 (faults)
	jmp	back3
