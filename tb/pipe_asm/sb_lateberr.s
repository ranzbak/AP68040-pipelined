; sb_lateberr.s - findings/storebuf/plan.md (Paul 2026-09-28, decision 2): a
; bus error on a POSTED store cannot be reported precisely -- the
; instruction retired long ago -- so the core stops, as on a double fault,
; instead of losing the store silently (PLAN D13: posted-store errors are
; fatal).  The store to $6004 is posted (RAM) and bus-errors on its way
; out ("lberr").  Only the stores before it reach memory.
; expect-berr: 6004 (lberr)
; Bus legs, PIPE_STORE_BUF=1 only (without posting the same store takes a
; precise access error instead, berr_write.s).
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
	move.l	#$11111111,(a0)
	move.l	#$22222222,4(a0)	; posted, bus-errors in the FIFO's drain
	move.l	#$33333333,8(a0)
	move.l	#$44444444,12(a0)
halt:	bra.s	halt

unexp:	bra.s	unexp

	org	$6000
	dcb.l	8,$eeeeeeee
