; berr_write.s - plan M6 tb_ap040_pipe_berr_write: a physical bus error on a
; data write (bus mode, synchronous stores).  On an instruction's last
; micro-op the write is reported pending in WB1 (WB1S = V | SIZE | TT | TM,
; WB1A = FA, WB1D = the data) and the stacked PC is the NEXT instruction
; (M68040UM 8.4.6.3 case 3); the handler completes WB1, as NetBSD's trap.c
; does, so the store lands exactly once.  On an earlier micro-op (MOVEM
; before its last register) the instruction restarts (PC = the MOVEM, WB1S
; clear, WB3A = FA, WB3D = the data).  SSW RW = 0.  Frames go to the log;
; the .exp is the bus-mode one, checked by hand.
; expect-berr: 7000 w 7014 w 7028 w 7032 w
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
	movea.l	#$7000,a0
	move.l	#$11223344,d0
	move.l	d0,(a0)		; faults: WB1 pending, PC = the next instruction
	moveq	#7,d7		; runs once after the handler
	movea.l	#$7010,a1
	move.l	#$A0A0A0A0,d1
	move.l	#$B1B1B1B1,d2
	move.l	#$C2C2C2C2,d3
	movem.l	d1-d3,(a1)	; $7014 (second of three) faults: the MOVEM restarts
	movea.l	#$7020,a2
	movem.l	d1-d3,(a2)	; $7028 (the last) faults: WB1 pending
	movea.l	#$7030,a3
	move.w	#$1234,(a3)
	addq.w	#1,2(a3)	; RMW at $7032: the store faults, WB1 pending, lands once
	move.l	a6,($7200).l	; log end: 4 frames
	move.l	d7,($7204).l
halt:
	bra.s	halt

; logs the frame, completes a pending WB1 (as NetBSD's trap.c)
h_berr:
	movem.l	d0-d1/a0-a1,-(a7)
	lea	16(a7),a0	; the frame
	moveq	#14,d0
.cp:	move.l	(a0)+,(a6)+
	dbf	d0,.cp
	lea	16(a7),a0
	move.w	$12(a0),d0	; WB1S
	btst	#7,d0
	beq.s	.out
	movea.l	$28(a0),a1	; WB1A
	move.l	$2C(a0),d1	; WB1D
	andi.w	#$60,d0
	beq.s	.long
	cmpi.w	#$20,d0
	beq.s	.byte
	move.w	d1,(a1)
	bra.s	.out
.long:	move.l	d1,(a1)
	bra.s	.out
.byte:	move.b	d1,(a1)
.out:	movem.l	(a7)+,d0-d1/a0-a1
	rte
unexp:
	bra.s	unexp

	org	$7030
	dc.w	$0000,$0055
