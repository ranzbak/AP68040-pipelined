; trace_t0.s - plan M9.T step 2: T0 traces only CHANGES OF FLOW.
;
; T0 (SR bit 14) traces a taken branch, a return, and the instructions the
; 68040 counts as pipeline synchronisation points -- the `t0_special` list
; the decoder now carries, copied verbatim from the reference core.  An
; ordinary straight-line instruction is NOT traced, which is the whole
; difference from T1 and what most of the cases below pin.
;
; What each case would catch:
;   1  a NOP is a synchronisation point and traces; a MOVEQ does not.
;   2  a TAKEN Bcc traces and a NOT-TAKEN one does not.  This is the case
;      only EA-fetch can answer: ID GUESSES every Bcc taken, so the
;      not-taken one is the one that redirects.
;   3  BSR and its RTS both trace (two changes of flow, not one).
;   4  MOVE to SR is a synchronisation point and traces, but a plain
;      MOVE from SR is not.
;   5  a traced STOP never enters the stopped state -- and under T0 only
;      when the SR it loads CHANGES T1/T0/S/M or the interrupt mask, which
;      is the reference's changed-bits rule: the STOP that rewrites the
;      same upper bits does NOT trace and WOULD hang if it stopped, since
;      nothing in this program raises an interrupt.
;   7  a T0 change-of-flow trace is resolved only once the TARGET is in
;      the pipeline, so an ILLEGAL there wins and CANCELS the trace (the
;      reference's flow_t0_pend).  A T1 trace is not: it is taken at the
;      boundary, before the target is looked at.
;   6  MOVEC TO a control register ($4E7B) traces; reading one back
;      ($4E7A) does not -- hardware narrowed this to the write direction
;      and cputest Basic/MOVEC2 depends on it.
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
	clr.l	$7004			; frames whose format/vector was not $2024
	clr.l	$7008			; the FIRST trace's stacked PC
	clr.l	$700C			; ... its format-$2 address field
	clr.l	$7010			; the LAST trace's stacked PC
	clr.l	$7014			; ... its format-$2 address field
	clr.l	$7018			; illegal instructions taken
	clr.l	$701C			; the sum of EVERY frame's address field
	clr.l	$7020			; ... and of every stacked PC
	moveq	#0,d7

;------------------------------------- 1: NOP traces, MOVEQ does not
	move.w	#$6700,sr		; T0 on, T1 off
n1:	nop				; +1
	moveq	#1,d0			; no
	moveq	#2,d0			; no

;------------------------------------- 2: taken and not-taken branches
	tst.l	d0			; sets Z = 0
	bne.s	b1			; TAKEN: +1
	nop
b1:	beq.s	b2			; NOT taken: no trace
	moveq	#3,d1
b2:

;------------------------------------- 3: BSR and RTS
	bsr.s	sub1			; +1 (and the RTS inside: +1)

;------------------------------------- 4: MOVE to SR traces, MOVE from SR not
	move.w	sr,d2			; no
	move.w	#$6700,sr		; +1 (and it re-arms T0)

;------------------------------------- 5: the STOP rule
	stop	#$6000			; the mask CHANGES, so the STOP is traced:
					; +1, and the stopped state is never entered.
					; (The negative half of the changed-bits rule
					; -- a STOP that rewrites the same upper bits
					; and so does NOT trace -- cannot be tested
					; here: an untraced STOP really does stop, and
					; nothing in this program raises an interrupt.
					; t_exceptions.s's interrupt section is where
					; that half belongs.)
	move.w	#$6700,sr		; +1

;------------------------------------- 6: MOVEC in and out
	movec	vbr,d3			; $4E7A: reads: no trace
	movec	d3,vbr			; $4E7B: writes: +1

;------------------------------------- 7: an exception at the TARGET wins
	bra.w	ill1			; a change of flow under T0, whose trace
ill1:	dc.w	$4AFC			; ... yields to this ILLEGAL: vector 4 is
cont:					; taken and the trace is CANCELLED
	move.w	#$2700,sr		; +1  (the last trace)
	nop				; not traced: the boundary it lands on
	bra	halt

sub1:
	moveq	#4,d4
	rts				; the return is the change of flow

;--------------------------------------------------------------- handlers
h_trace:
	addq.l	#1,$7000
	cmpi.w	#$2024,6(sp)
	beq.s	ht_fmt
	addq.l	#1,$7004
ht_fmt:
	tst.l	d7
	bne.s	ht_notfirst
	moveq	#1,d7
	move.l	2(sp),$7008
	move.l	8(sp),$700C
ht_notfirst:
	move.l	2(sp),$7010
	move.l	8(sp),$7014
	; ... and a sum over EVERY frame, because a count with the first and
	; the last pinned cannot see two neighbouring instructions SWAP which
	; of them traced -- the same blind spot a round trip has for a
	; symmetric permutation (plan 2.1 item 6).  The MOVEC direction rule
	; is exactly such a pair.
	move.l	8(sp),d6
	add.l	d6,$701C
	move.l	2(sp),d6
	add.l	d6,$7020
	rte

h_ill:
	addq.l	#1,$7018
	move.l	#cont,2(sp)		; resume after the ILLEGAL word
	rte

unexp:
	bra.s	unexp

; clear of every handler: the bench stops at the first retire whose PC is
; the halt PC, and an exception's micro-ops retire tagged with the PC of the
; instruction they were taken in front of.
halt:
	bra.s	halt
