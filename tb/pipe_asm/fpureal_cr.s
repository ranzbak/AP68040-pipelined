; fpureal_cr.s - plan M10.2: FMOVE(M).L between an effective address and
; FPCR / FPSR / FPIAR (opclass 100 and 101), against the REAL ap040_fpu.
;
; One longword per selected register, in FPCR, FPSR, FPIAR order at
; ascending addresses; an EMPTY register list means FPIAR; a data register
; carries one register only and an address register only FPIAR; an
; immediate operand is a source and carries the whole list from the
; instruction stream.
;
; What each case would catch:
;   1    FPCR written and read back -- and then PROVED to have reached the
;        unit, because the same 1.0/3.0 divide is truncated under RZ and
;        rounded up under RN.  A register that is written but not wired
;        would pass a read-back and fail this.
;   2    FPSR read: the divide above set INEX2 and accrued INEX.
;   3    an IMMEDIATE list of two registers.  It is also the length check:
;        with the immediate sized as one longword (the bug this step fixed
;        in shape()) the next instruction would be decoded from the middle
;        of the immediate and nothing after it would run.  `noread` says
;        the words come from the instruction stream, never from a data read.
;   4    three registers from memory through (A0)+, then back out to (A5)+:
;        the order, and the (An)+ step of 4 per register.
;   5    -(An): the same three registers written at An-12.
;   6    An as the operand, which only FPIAR may use.
;   7    an empty list: FPIAR.
;   8    FPIAR is NOT written by a control-register move (PRM: a move to or
;        from a control register leaves FPIAR alone), so after an FADD at a
;        known address and two control moves it still reads that address.
;   9-11 the legality rules, each an ordinary F-line: a data register with
;        two registers selected, an address register with a list that is
;        not FPIAR alone, and an immediate as the DESTINATION.  The frame
;        is checked as deltas against vector 11 / format $0 / own PC.
;
; FPCR's enable byte is left at zero throughout: the arithmetic-exception
; port is not wired yet (plan M10.1 step (d)), and an enabled exception
; would not even pulse `done`.
;
; diff: --cycles 120000
v_flin	equ	h_fl
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
	movea.l	#$5000,a0		; the control-register images
	movea.l	#$5100,a1		; the two divides
	movea.l	#$5150,a5		; the control-register round trip

;------------------------------------- 1: FPCR reaches the unit
	dc.w	$F23C,$9000,$0000,$0010	; FMOVE.L #$10,FPCR   -- round to zero
	dc.w	$F200,$B000		; FMOVE.L FPCR,D0
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F23C,$4080,$0000,$0003	; FMOVE.L #3,FP1
	dc.w	$F200,$0420		; FDIV    FP1,FP0
;------------------------------------- 2: FPSR carries the divide's INEX
	dc.w	$F201,$A800		; FMOVE.L FPSR,D1
	andi.l	#$208,d1		; INEX2 and accrued INEX
	dc.w	$F219,$6800		; FMOVE.X FP0,(A1)+   -- truncated
	dc.w	$F23C,$9000,$0000,$0000	; FMOVE.L #0,FPCR     -- round to nearest
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F200,$0420		; FDIV    FP1,FP0
	dc.w	$F219,$6800		; FMOVE.X FP0,(A1)+   -- rounded up

;------------------------------------- 3: an immediate list of two
i2:	dc.w	$F23C,$9800
	dc.w	$0000,$0030		; FPCR
	dc.w	$0000,$0208		; FPSR -- NOT zero, so that a mis-sized
					;         immediate (fpw) leaves the stream
					;         decoding it as ORI.B #8,D0 and D0 shows it
	dc.w	$F203,$B000		; FMOVE.L FPCR,D3
	dc.w	$F204,$A800		; FMOVE.L FPSR,D4

;------------------------------------- 4: three registers, (A0)+ then (A5)+
	dc.w	$F218,$9C00		; FMOVEM.L (A0)+,FPCR/FPSR/FPIAR
	dc.w	$F21D,$BC00		; FMOVEM.L FPCR/FPSR/FPIAR,(A5)+

;------------------------------------- 5: the predecrement destination
	movea.l	#$5210,a2
	dc.w	$F222,$BC00		; FMOVEM.L FPCR/FPSR/FPIAR,-(A2)

;------------------------------------- 6: An, which only FPIAR may use
	movea.l	#$ABCD0000,a3
	dc.w	$F20B,$8400		; FMOVE.L A3,FPIAR
	dc.w	$F20C,$A400		; FMOVE.L FPIAR,A4

;------------------------------------- 7: an empty list is FPIAR
	dc.w	$F205,$A000		; FMOVE.L FPIAR,D5

;------------------------------------- 8: a control move leaves FPIAR alone
	bra	arith			; (the gap to $700 is not code)
	org	$700
arith:	dc.w	$F200,$0422		; FADD    FP1,FP0   -- FPIAR = $700
	dc.w	$F207,$B000		; FMOVE.L FPCR,D7
	dc.w	$F206,$A400		; FMOVE.L FPIAR,D6

;------------------------------------- 9, 10, 11: the legality rules.  Each
; is the ordinary F-line -- vector 11, format $0, the instruction's OWN PC --
; and not M10.0's format $4, because with an FPU the effective address has
; been looked at (lib/AP68040's fp_crm arm; PLAN.md D20).
	bra	ill
	org	$740
ill:
	clr.l	$7000			; the counter and the two delta accumulators
	clr.l	$7004
	clr.l	$7008
	movea.l	#c9e,a6
	movea.l	#c9,a3
c9:	dc.w	$F200,$9800		; FMOVEM.L D0,FPCR/FPSR -- Dn takes one only
c9e:
	movea.l	#c10e,a6
	movea.l	#c10,a3
c10:	dc.w	$F20A,$8800		; FMOVE.L A2,FPSR       -- An takes FPIAR only
c10e:
	movea.l	#c11e,a6
	movea.l	#c11,a3
c11:	dc.w	$F23C,$A400,$0000,$0000	; FMOVE.L FPIAR,#imm    -- no such destination
c11e:
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a3 = the faulting instruction's own PC, a6 = where to resume.  Records how
; many F-lines were taken and the deltas of the frame against what the rule
; says, so the expect file holds zeros and no absolute address.
h_fl:
	addq.l	#1,$7000
	moveq	#0,d2
	move.w	6(sp),d2
	sub.l	#$002C,d2		; format $0, vector 11
	add.l	d2,$7004
	move.l	2(sp),d2
	sub.l	a3,d2			; the instruction's own PC
	add.l	d2,$7008
	move.l	a6,2(sp)
	rte

unexp:
	bra.s	unexp

;--------------------------------------------------------------- operands
	org	$5000
	dc.l	$00000030		; FPCR
	dc.l	$00000200		; FPSR
	dc.l	$12345678		; FPIAR
