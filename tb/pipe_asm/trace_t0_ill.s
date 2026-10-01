; trace_t0_ill.s - a T0 trace is taken BEFORE the next instruction's own
; exception (cputest on the board, findings/ap040-pipelined/tests/cputest/
; board: 40 instructions "Expected trace exception but got none").
;
; cputest enters every test the same way: an RTE whose format-0 frame holds
; the test's SR (here with T0 set) and PC, and an ILLEGAL right after the test
; instruction, or at its branch target.  The traced instruction completes,
; the trace is processed at the boundary (vector 9, format $2, stacked PC =
; the ILLEGAL, address field = the traced instruction), the trace handler
; returns, and only then does the ILLEGAL take vector 4.  An exception that
; belongs to the NEXT instruction cannot cancel the trace of this one; the
; core used to let a T0-only trace yield to it (tr_yield).
;
; What each case would catch:
;   1  BRA under T0 to an ILLEGAL (cputest Bcc.B): trace, then vector 4.
;   2  NOP under T0 (a synchronisation point) followed by an ILLEGAL
;      (cputest NOP): trace, then vector 4.
;   3  ANDI #0,SR in supervisor mode with T0 set (cputest ANDSR.W): traced on
;      the T0 it STARTED with, then vector 4 with T0 now clear.
;   4  MOVEQ under T0 followed by an ILLEGAL: no change of flow, no trace,
;      only vector 4 (the control: the fix must not trace everything).
;
; diff: --cycles 60000
; expect-range: 7000 7020
v_trace	equ	h_trace
v_ill	equ	h_ill
v_adr	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; traces taken
	clr.l	$7004			; illegals taken
	clr.l	$7008			; order: each trace adds 1, each illegal
					; multiplies by 4 (so 1,4 order differs)
	clr.l	$700C			; sum of the traces' stacked PCs
	clr.l	$7010			; sum of the traces' address fields
	clr.l	$7014			; sum of the illegals' stacked PCs
	move.l	#-1,$7018		; the SR stacked by the case-3 ILLEGAL (low word)
	clr.l	$701C			; frames not format $2 / vector $24
	lea	$1800,a0
	move.l	a0,usp

;------------------------------------- 1: BRA to an ILLEGAL, user mode
	move.l	#c2,cont
	clr.w	-(sp)			; format 0, vector 0
	pea	t1			; PC
	move.w	#$4000,-(sp)		; SR: T0, user
	rte
;------------------------------------- 2: NOP then ILLEGAL, user mode
c2:	move.l	#c3,cont
	clr.w	-(sp)
	pea	t2
	move.w	#$4000,-(sp)
	rte
;------------------------------------- 3: ANDI #0,SR, supervisor with T0
c3:	move.l	#c4,cont
	clr.w	-(sp)
	pea	t3
	move.w	#$6000,-(sp)		; SR: T0, S
	rte
;------------------------------------- 4: MOVEQ then ILLEGAL (no trace)
c4:	move.l	#c5,cont
	clr.w	-(sp)
	pea	t4
	move.w	#$4000,-(sp)
	rte
c5:	bra	halt

; the test instructions
t1:	bra.s	t1i			; traced: change of flow
	nop
t1i:	dc.w	$4AFC
t2:	nop				; traced: synchronisation point
t2i:	dc.w	$4AFC
t3:	andi.w	#0,sr			; traced on its starting T0
t3i:	dc.w	$4AFC
t4:	moveq	#1,d0			; not traced
t4i:	dc.w	$4AFC

;--------------------------------------------------------------- handlers
h_trace:
	addq.l	#1,$7000
	addq.l	#1,$7008
	cmpi.w	#$2024,6(sp)
	beq.s	ht_fmt
	addq.l	#1,$701C
ht_fmt:	move.l	2(sp),d6
	add.l	d6,$700C
	move.l	8(sp),d6
	add.l	d6,$7010
	rte

h_ill:
	addq.l	#1,$7004
	move.l	$7008,d6
	lsl.l	#2,d6
	move.l	d6,$7008
	move.l	2(sp),d6
	add.l	d6,$7014
	move.w	(sp),d6
	cmp.l	#t3i,2(sp)
	bne.s	hi_n3
	move.w	d6,$701A
hi_n3:	move.w	#$2700,(sp)		; back to supervisor, T0 off
	move.l	cont,2(sp)
	rte

cont:	dc.l	0

unexp:
	bra.s	unexp

halt:
	bra.s	halt
