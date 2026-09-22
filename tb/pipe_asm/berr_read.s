; berr_read.s - plan M6 tb_ap040_pipe_berr_read: a physical bus error on a
; data read (bus mode: the bench rejects the first read of each address
; below) -- vector 2, format $7, stacked PC = the faulting instruction
; (restart), SSW ATC clear / RW set / SIZE / TM = 5 (supervisor data) or 1
; (user), FA = EA = the first byte of the transfer, WB1S-WB3S clear, WB3A =
; FA; the RTE restarts the instruction, which then succeeds; its (An)+
; update happens once; a MOVEM that faults part way sets SSW CM with EA =
; its calculated EA (PLAN D15) and loads every register on the restart, its
; base register included.  The handler copies each
; frame to the log.  (The L1 run has no bus errors: the handler is never
; entered and the log stays empty there -- the .exp is the bus-mode one,
; written by hand from M68040UM 8.4.6 and lib/AP68040 aerr_word.)
; expect-berr: 7000 r 7011 r 7026 r 7104 r 7304 r
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
v_berr	equ	h_berr
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$7800,a6	; frame log
	movea.l	#$7000,a0
	move.l	(a0)+,d0	; faults once: restart, a0 +4 once
	move.l	d0,($7200).l
	move.l	a0,($7204).l
	move.w	($7010).l,d1	; word at $7010 covers the armed $7011
	move.l	d1,($7208).l
	movea.l	#$7020,a1
	move.b	6(a1),d2	; byte at $7026
	move.l	d2,($720c).l
	movea.l	#$7100,a2
	movem.l	(a2),d3-d5/a3	; the second longword ($7104) faults
	move.l	d3,($7210).l
	move.l	d4,($7214).l
	move.l	d5,($7218).l
	move.l	a3,($721c).l
	; the base register loaded before the fault: the restart must use the
	; original base (it is written only with the last register)
	movea.l	#$7300,a4
	movem.l	(a4),a4/a5	; $7304 faults after a4 is loaded
	move.l	a4,($7224).l	; ($7300) = $00007400
	move.l	a5,($7228).l	; ($7304) = $55667788
	move.l	a6,($7220).l	; log end: 5 frames of 60 bytes
halt:
	bra.s	halt

h_berr:
	movem.l	d0/a0,-(a7)
	lea	8(a7),a0	; the frame
	moveq	#14,d0
.cp:	move.l	(a0)+,(a6)+
	dbf	d0,.cp
	movem.l	(a7)+,d0/a0
	rte
unexp:
	bra.s	unexp

	org	$7000
	dc.l	$11223344
	org	$7010
	dc.w	$5566
	org	$7020
	dc.b	0,0,0,0,0,0,$77,0
	org	$7100
	dc.l	$AAAA0001,$AAAA0002,$AAAA0003,$AAAA0004
	org	$7300
	dc.l	$00007400,$55667788
	org	$7400
	dc.l	$DEADDEAD,$BAD0BAD0
