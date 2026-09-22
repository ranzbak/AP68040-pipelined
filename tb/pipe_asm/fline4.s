; fline4.s - plan M10.0: the MC68LC040's eight-word format $4 frame for an
; unimplemented floating-point instruction, and the cases that do NOT get it.
;
; M68040UM Appendix A.5.2, Table 12-1 (p. A-6/A-7): with no FPU every
; well-formed coprocessor-id-1 instruction takes vector 11 with
;   SP+$00 SR, SP+$02 PC of the NEXT instruction, SP+$06 $4|vector offset,
;   SP+$08 effective address, SP+$0C PC of the faulted instruction.
; The MC68040 proper neither generates nor recognises format $4.
;
; PLAN.md divergence D18 settles what is NOT a floating-point instruction:
;   * an extension word with the reserved opclass (bits 15:13 = 001)
;   * an opmode in fp_opmode_class()'s F-line class
;   * a coprocessor id that is not 1
; take vector 11 with the ordinary four-word format $0 frame and the
; instruction's OWN PC, and an opmode in $78..$7F takes vector 4.
;
; Each case records five longwords at (a6)+:
;   tag, (format/vector word - expected), (stacked PC - expected),
;   (EA - expected), (faulted PC - expected)
; so every delta is zero when the core is right and the .exp file is the
; tags with zeros between them -- no absolute address ever appears in it.
; The two frame fields that format $0 does not have are recorded as zero.
;
; diff: --cycles 40000
; expect-range: 7000 70F0
; expect-skip: d0 d1 d7 a0 a1 a2 a3 a4 a5 a6
v_flin	equ	h_flin
v_ill	equ	h_ill
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

; set up one case: \1 tag, \2 expected format/vector word
setup	macro
	move.l	#\1,(a6)+
	move.l	#\2,d7
	endm

	org	$400
start:
	movea.l	#$7000,a6
	movea.l	#$5000,a0		; the operand pointer the memory cases use
	suba.l	a3,a3			; default expected EA: none

;--------------------------------------------------------------- format $4
; 1: FADD.X FP1,FP0 -- register to register, no memory operand, EA = 0
	setup	1,$402C
	lea	c1(pc),a4
	lea	c1e(pc),a5
	lea	c1e(pc),a1
	suba.l	a3,a3
c1:	dc.w	$F200,$0422
c1e:

; 2: FADD.L #$12345678,FP0 -- an immediate source is FOUR words long and its
;    EA is 0, NOT the address of the immediate data (D18)
	setup	2,$402C
	lea	c2(pc),a4
	lea	c2e(pc),a5
	lea	c2e(pc),a1
	suba.l	a3,a3
c2:	dc.w	$F23C,$4022,$1234,$5678
c2e:

; 3: FADD.X (A0),FP0 -- a memory operand: EA = A0
	setup	3,$402C
	lea	c3(pc),a4
	lea	c3e(pc),a5
	lea	c3e(pc),a1
	movea.l	a0,a3
c3:	dc.w	$F210,$4822
c3e:

; 4: FMOVE.L FP0,D1 -- opclass 011 with a register destination: EA = 0
	setup	4,$402C
	lea	c4(pc),a4
	lea	c4e(pc),a5
	lea	c4e(pc),a1
	suba.l	a3,a3
c4:	dc.w	$F201,$6000
c4e:

; 5: FMOVEM.X (A0)+,FP0-FP2 -- EA = A0 (the register is NOT updated: the
;    instruction never executes)
	setup	5,$402C
	lea	c5(pc),a4
	lea	c5e(pc),a5
	lea	c5e(pc),a1
	movea.l	a0,a3
c5:	dc.w	$F218,$D0E0
c5e:

; 6: FBNE.W -- the stacked PC is the instruction AFTER the FBcc whether or
;    not the branch would be taken, because the fault precedes the condition
	setup	6,$402C
	lea	c6(pc),a4
	lea	c6e(pc),a5
	lea	c6e(pc),a1
	suba.l	a3,a3
c6:	dc.w	$F28E,$0010
c6e:

; 7: FSAVE (A0) -- EA = A0
	setup	7,$402C
	lea	c7(pc),a4
	lea	c7e(pc),a5
	lea	c7e(pc),a1
	movea.l	a0,a3
c7:	dc.w	$F310
c7e:

; 8: FRESTORE (A0)+ -- EA = A0
	setup	8,$402C
	lea	c8(pc),a4
	lea	c8e(pc),a5
	lea	c8e(pc),a1
	movea.l	a0,a3
c8:	dc.w	$F358
c8e:

;--------------------------------------------------------------- format $0
; 9: the reserved opclass (extension bits 15:13 = 001): format $0, own PC
	setup	9,$002C
	lea	c9(pc),a4
	lea	c9(pc),a5
	lea	c9e(pc),a1
	suba.l	a3,a3
c9:	dc.w	$F200,$2000
c9e:

; 10: an opmode in the F-line class ($05): format $0, own PC
	setup	10,$002C
	lea	c10(pc),a4
	lea	c10(pc),a5
	lea	c10e(pc),a1
	suba.l	a3,a3
c10:	dc.w	$F200,$0005
c10e:

; 11: opmode $78 -- vector 4 (illegal instruction), not vector 11
	setup	11,$0010
	lea	c11(pc),a4
	lea	c11(pc),a5
	lea	c11e(pc),a1
	suba.l	a3,a3
c11:	dc.w	$F200,$0078
c11e:

; 12: coprocessor id 0 -- an ordinary F-line, one word, format $0, own PC
	setup	12,$002C
	lea	c12(pc),a4
	lea	c12(pc),a5
	lea	c12e(pc),a1
	suba.l	a3,a3
c12:	dc.w	$F000
c12e:

halt:
	bra.s	halt

;--------------------------------------------------------------- handlers
; a1 = where to resume, a3 = expected EA, a4 = expected faulted PC,
; a5 = expected stacked PC, d7 = expected format/vector word.
; Clobbers d0, d1, a2 -- no case depends on them.
h_flin:
h_ill:
	movea.l	sp,a2
	moveq	#0,d0
	move.w	6(a2),d0
	sub.l	d7,d0
	move.l	d0,(a6)+		; format/vector delta
	move.l	2(a2),d0
	sub.l	a5,d0
	move.l	d0,(a6)+		; stacked-PC delta
	moveq	#0,d1
	move.w	6(a2),d1
	andi.w	#$F000,d1
	cmpi.w	#$4000,d1
	bne.s	hf_short
	move.l	8(a2),d0
	sub.l	a3,d0
	move.l	d0,(a6)+		; EA delta
	move.l	12(a2),d0
	sub.l	a4,d0
	move.l	d0,(a6)+		; faulted-PC delta
	bra.s	hf_fix
hf_short:
	clr.l	(a6)+
	clr.l	(a6)+
hf_fix:
	move.l	a1,2(a2)		; resume past the instruction
	rte

unexp:
	bra.s	unexp
