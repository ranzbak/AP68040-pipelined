; trace_t1.s - plan M9.T: T1 traces EVERY instruction.
;
; The trace is a POST-instruction exception: the instruction completes, and
; the trace is taken in front of the next one.  Vector 9, format $2, so the
; format/vector word is $2024 (the vector OFFSET, 9 * 4), the stacked PC is
; the NEXT instruction and the format-$2 address field is the PC of the
; instruction that was traced (M68040UM 8.2.6; reference ap040_core.v's
; fetch_next: `exc(VEC_TRACE, 4'd2, pc, pc_i)`).
;
; What each case would catch:
;   1  the T bits are sampled at the START of an instruction: the MOVE to SR
;      that SETS T1 is not itself traced, and the one that CLEARS it is.
;   2  the stacked PC is the next instruction and the address field is the
;      traced one -- checked absolutely against the program's own labels for
;      the first and the last trace, not merely as a difference.
;   3  exception entry clears T1/T0, so the handler does not trace itself,
;      while the STACKED SR still has T1 set and the RTE resumes tracing.
;   4  an instruction that takes an exception takes ONLY that exception:
;      a traced TRAP #0 produces one trap and no trace (the reference core
;      clears any pending trace inside exc(), and hardware agrees --
;      cputest basic/all reported "Got unexpected trace exception" when it
;      did not).
;
; diff: --cycles 40000
; expect-range: 7000 7024
v_trace	equ	h_trace
v_trp0	equ	h_trap
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; traces taken
	clr.l	$7004			; frames whose format/vector was not $2024
	clr.l	$7008			; traces whose own handler SR still had T set
	clr.l	$700C			; the FIRST trace's stacked PC
	clr.l	$7010			; ... its format-$2 address field
	clr.l	$7014			; ... its stacked SR, in the low word
	clr.l	$7018			; the LAST trace's stacked PC
	clr.l	$701C			; ... its format-$2 address field
	clr.l	$7020			; TRAP #0 taken
	moveq	#0,d7			; set once the first frame is captured

;------------------------------------- 1, 2, 3: straight-line instructions
	move.w	#$A700,sr		; T1 on.  NOT traced: T was clear at its start
t1:	nop
t2:	moveq	#5,d0
t3:	addq.l	#1,d0
t4:	move.l	#$12345678,d1		; a longer instruction: the stacked PC moves by 6
t5:	move.w	#$2700,sr		; traced: T1 was set when it started
t6:	nop				; not traced

;------------------------------------- 4: the exception wins, the trace is lost
	move.w	#$A700,sr
t7:	trap	#0			; vector 32 only
t8:	nop				; traced (the RTE restored T1)
t9:	move.w	#$2700,sr		; traced
t10:	nop				; not traced: the last trace's boundary
	bra	halt

;--------------------------------------------------------------- handlers
h_trace:
	addq.l	#1,$7000
	cmpi.w	#$2024,6(sp)		; format $2, vector offset $24
	beq.s	ht_fmt
	addq.l	#1,$7004
ht_fmt:
	move.w	sr,d6			; the handler's own T bits must be clear
	andi.w	#$C000,d6
	beq.s	ht_tclr
	addq.l	#1,$7008
ht_tclr:
	tst.l	d7
	bne.s	ht_notfirst
	moveq	#1,d7
	move.l	2(sp),$700C
	move.l	8(sp),$7010
	move.w	(sp),$7016
ht_notfirst:
	move.l	2(sp),$7018
	move.l	8(sp),$701C
	rte

h_trap:
	addq.l	#1,$7020
	rte

unexp:
	bra.s	unexp

; The halt loop sits clear of every handler.  The bench stops the run at the
; first retire whose PC is the halt PC, and an exception's own micro-ops
; retire tagged with the PC of the instruction they were taken in front of --
; so a halt label next to the traced block can end the run early.
halt:
	bra.s	halt
