; sb_order.s - findings/storebuf/plan.md stage 0: stores to RAM, then a
; store and reads in the bench's I/O page ($F000-$FFFF, never posted).
; Every store reaches memory in program order and every read on the port
; goes only once every older store is in memory (tb_sb_check.v, bus legs):
; an I/O store waits behind the posted ones, an I/O read waits for them.
; The program also reads back what the ordering decides.  Hand-computed.
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
	lea	$f000,a1
; 1 three posted stores, an I/O store, an I/O read of it
	move.l	#$00000001,(a0)
	move.l	#$00000002,4(a0)
	move.l	#$00000003,8(a0)
	move.w	#$1234,$10(a1)
	move.w	$10(a1),d0		; 00001234
; 2 a posted store right before an I/O read of the same RAM it wrote,
;   through the I/O page's alias-free address: the read must wait
	move.l	#$00000004,12(a0)
	move.l	$20(a1),d1		; $f020 = 0badf00d (image)
; 3 alternating: RAM, I/O, RAM, I/O -- stores only
	move.l	#$00000005,16(a0)
	move.b	#$55,$30(a1)
	move.l	#$00000006,20(a0)
	move.b	#$66,$31(a1)
	move.w	$30(a1),d2		; 5566
; 4 a burst of RAM stores behind an I/O store, then a RAM read
	move.w	#$abcd,$40(a1)
	move.l	#$00000007,24(a0)
	move.l	#$00000008,28(a0)
	move.l	#$00000009,32(a0)
	move.l	#$0000000a,36(a0)
	move.l	#$0000000b,40(a0)
	move.l	(a0),d3
	add.l	40(a0),d3		; 0000000c
	move.w	$40(a1),d4		; abcd
halt:	bra.s	halt

unexp:	bra.s	unexp

	org	$6000
	dcb.l	16,$eeeeeeee
	org	$f000
	dcb.l	8,$eeeeeeee
	org	$f020
	dc.l	$0badf00d
	dcb.l	8,$eeeeeeee
