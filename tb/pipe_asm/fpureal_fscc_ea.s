; fpureal_fscc_ea.s - FScc to a memory destination that UPDATES its
; register: (An)+ and -(An) step by one byte (two for A7), the byte goes to
; the address before the step (after it for -(An)), and nothing else is
; written.  cputest on the board (tests/cputest/board, fint/FScc):
; `fsf (a6)+` left A6 two bytes on and the byte unwritten at A6 -- decode
; gives FScc the same EA as source AND destination, and EA-calc stepped the
; register for each of them.
;
; What each case would catch:
;   1  FSGT (A1)+ then FSLE (A1)+: $FF and $00 at $6000/$6001, A1 = $6002
;      (a double step leaves A1 at $6004 and the bytes at $6001/$6003).
;   2  FSGT -(A2): $FF at $600F, A2 = $600F.
;   3  FSGT (A7)+: the stack pointer steps by TWO for a byte, $FF at $6020.
;   4  the guard bytes around every target keep $AA.
;
; diff: --cycles 60000
v_flin	equ	unexp
v_fpun	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	lea	$6000,a0		; guard pattern over $6000-$602F
	move.l	#$AAAAAAAA,d0
	moveq	#11,d1
fill:	move.l	d0,(a0)+
	dbra	d1,fill
	fmove.l	#5,fp0
	fcmp.l	#3,fp0			; 5 > 3: GT true, LE false

;------------------------------------- 1: (An)+
	lea	$6000,a1
	fsgt	(a1)+			; $FF at $6000
	fsle	(a1)+			; $00 at $6001
;------------------------------------- 2: -(An)
	lea	$6010,a2
	fsgt	-(a2)			; $FF at $600F
;------------------------------------- 3: (A7)+ steps by two
	move.l	sp,d7
	lea	$6020,sp
	fsgt	(sp)+			; $FF at $6020, SP = $6022
	move.l	sp,d6
	move.l	d7,sp
	bra.s	halt

unexp:
	bra.s	unexp

halt:
	bra.s	halt
