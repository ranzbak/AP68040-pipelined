; rte_oddpc.s - audit 2026-09-27, finding 5: an RTE whose restored PC is
; odd takes the address error with the stacked SR's S bit SET -- $A700 for a
; restored SR of $8700 (T1, user, IPL 7) -- not the restored SR image
; (M68040UM 8.4 and the 1998 addendum, p. 2).  The frame is format $2,
; vector 3, PC = the RTE, address = the restored PC.
; diff: --cycles 20000
v_adr	equ	h_adr
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000
	move.w	#$0000,-(sp)		; format $0, vector 0
	move.l	#$00000601,-(sp)	; an ODD PC
	move.w	#$8700,-(sp)		; SR: T1, user, IPL 7
r:	rte
halt:	bra.s	halt

h_adr:	moveq	#0,d7
	move.w	(sp),d7
	move.l	d7,$7000		; stacked SR
	move.w	6(sp),d7
	move.l	d7,$7004		; format/vector
	move.l	2(sp),$7008		; stacked PC
	move.l	8(sp),$700C		; the fault address
	lea	$1F00,sp
	bra.s	halt

unexp:	bra.s	unexp
