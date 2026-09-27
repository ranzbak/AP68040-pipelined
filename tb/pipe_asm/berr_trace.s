; berr_trace.s - audit 2026-09-27, finding 2: a TRACED store whose write
; faults.  The trace the store armed was left pending through the access
; error's entry, and every read -- the vector fetch included -- waits while a
; trace is pending: the core deadlocked.  The fault is on the instruction's
; last micro-op (the write pending in WB1, the stacked PC past it), so the
; instruction completed and its trace must survive: SSW CT set, and the RTE
; takes the trace (M68040UM 8.4.6.2 SSW CT; 8.3).
;
; Bus mode only: the bench rejects the FIRST write of $7000.
;   the berr handler logs the SSW's CT bit, completes the WB1 write, RTEs;
;   the trace handler logs every stacked PC: the first after the RTE (the
;   store's trace, PC = the ANDI), then the ANDI's own (T1 still set when it
;   started), PC = the instruction after it.
;
; expect-berr: 7000 w
; diff: --cycles 40000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
v_berr	equ	h_berr
v_trace	equ	h_trace
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$7800,a6		; trace log
	clr.l	$7200			; access errors
	clr.l	$7204			; CT seen
	lea	$7000,a0
	move.l	#$11223344,d0
	ori.w	#$8000,sr		; T1: trace every instruction from here
st:	move.l	d0,(a0)			; traced; its write faults (pending WB1)
an:	andi.w	#$7FFF,sr		; traced too; clears T1
aft:	move.l	(a0),$7208		; the store is in memory
halt:	bra.s	halt

h_berr:	movem.l	d7/a5,-(sp)
	addq.l	#1,$7200
	move.w	$14(sp),d7		; SSW
	andi.l	#$2000,d7		; CT
	move.l	d7,$7204
	move.w	$1A(sp),d7		; WB1S
	btst	#7,d7
	beq.s	.nwb
	movea.l	$30(sp),a5		; WB1A
	move.l	$34(sp),(a5)		; WB1D
.nwb:	movem.l	(sp)+,d7/a5
	rte

h_trace:
	move.l	2(sp),(a6)+		; stacked PC
	rte

unexp:	bra.s	unexp
