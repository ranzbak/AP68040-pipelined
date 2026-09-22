; berr_flush.s - plan M6 tb_ap040_pipe_fault_flush: a fault on instruction
; k while k+1 (an (An)+ load) is already in the pipe and k+2 is a taken
; branch: k+1 and k+2 have no architectural effect before the fault -- A1 is
; incremented once, the branch is taken once, the skipped ADDQ never runs.
; Bus mode only (the read of $7000 is rejected once).
; expect-berr: 7000 r
; expect-mem: m32 7200 m32 7204 m32 7208 m32 720c
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
	movea.l	#$7000,a0
	movea.l	#$7100,a1
	moveq	#0,d7
	moveq	#0,d6
	move.l	(a0),d0		; k: faults once, restarts
	move.l	(a1)+,d1	; k+1
	bra.s	over		; k+2
	addq.l	#1,d7		; never
over:	addq.l	#1,d6
	move.l	a1,($7200).l	; $7104: once
	move.l	d7,($7204).l	; 0
	move.l	d6,($7208).l	; 1
	move.l	d0,($720c).l
halt:
	bra.s	halt
h_berr:	addq.w	#1,($7210).l
	rte
unexp:
	bra.s	unexp

	org	$7000
	dc.l	$12345678
	org	$7100
	dc.l	$0BADF00D
	org	$7210
	dc.w	0
