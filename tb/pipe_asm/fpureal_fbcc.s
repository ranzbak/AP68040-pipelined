; fpureal_fbcc.s - plan M10.8: the floating-point conditional predicates,
; FBcc / FScc / FDBcc / FTRAPcc, and BSUN.
;
; The condition comes from the unit's FPSR condition codes, which is why
; every one of these decodes to CL_FPU like the rest: reading `fpcc` while
; a released operation is still running is the DATA hazard M10.1(c) named,
; and the serialise + background wait is what makes it safe.
;
; What each case would catch:
;   1  FBcc taken and not taken, on a comparison whose result is known.
;   2  the predicate table: EQ, NE, GT, LT, GE, LE against 5 vs 3.
;   3  FScc into a data register and into memory: a byte of all ones or
;      all zeros, and nothing outside that byte.
;   4  FDBcc: the condition false, so it counts Dn.w down and branches
;      until the counter passes -1.
;   5  BSUN: a SIGNALLING predicate (bit 4 of the field) that meets an
;      unordered result records BSUN in FPSR whether or not the trap is
;      enabled...
;   6  ... and takes vector 48 when FPCR enables it.
;   7  bit 5 of the six-bit predicate field ALIASES -- WinUAE's fpp_cond
;      masks with $1F -- so an encoding with it set behaves like the one
;      without and is not a trap.
;
; diff: --cycles 120000
v_flin	equ	unexp
v_fpun	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
v_fparith equ	h_bsun
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; BSUN traps taken
	clr.l	$7004			; wrong-way branches
	clr.l	$7008			; the BSUN frame's format/vector delta
	clr.l	$700C			; ... and its stacked-PC delta
	movea.l	#$5100,a1

	fmove.l	#5,fp0
	fmove.l	#3,fp1
	fcmp.x	fp1,fp0			; 5 - 3: not equal, greater, ordered

;------------------------------------- 1, 2: the predicates
	fbgt	p1
	addq.l	#1,$7004
p1:	fble	pbad
	fbeq	pbad
	fbne	p2
	addq.l	#1,$7004
p2:	fbge	p3
	addq.l	#1,$7004
p3:	fblt	pbad
	fbor	p4			; ordered
	addq.l	#1,$7004
p4:	fbun	pbad			; not unordered
	bra.s	p5
pbad:	addq.l	#1,$7004
p5:

;------------------------------------- 3: FScc
	fsgt	d0			; $FF
	fsle	d1			; $00
	fsgt	(a1)			; a byte in memory
	addq.l	#1,a1
	fsle	(a1)
	addq.l	#1,a1

;------------------------------------- 4: FDBcc counts down while FALSE
	moveq	#3,d2
dbl:	addq.l	#1,d3
	fdbeq	d2,dbl			; equal is FALSE, so it counts 3,2,1,0,-1

;------------------------------------- 5: BSUN without the enable
	fmove.l	#0,fp2
	fmove.l	#0,fp3
	fdiv.x	fp3,fp2			; 0/0 -> a NaN, OPERR
	fmove.l	#0,fpsr			; clear the status the divide left
	fcmp.x	fp2,fp0			; compare against the NaN: unordered
	fbgt	b1			; GT is SIGNALLING: records BSUN, no trap
b1:	fmove.l	fpsr,d4
	andi.l	#$8000,d4		; the BSUN bit of the exception byte

;------------------------------------- 6: BSUN with the enable
	fmove.l	#$8000,fpcr		; BSUN enabled
	fmove.l	#0,fpsr			; ... which also clears the condition codes,
	fcmp.x	fp2,fp0			; so the unordered compare has to be redone
	movea.l	#c6e,a6
	movea.l	#c6,a5
c6:	fbgt	c6e			; -> vector 48
c6e:
	fmove.l	#0,fpcr

;------------------------------------- 7: the aliasing bit 5
	fmove.l	#0,fpsr
	fcmp.x	fp1,fp0			; ordered again, 5 > 3
	dc.w	$F2B2,$0004		; fbgt.w with bit 5 of the predicate SET
	addq.l	#1,$7004
	nop
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a5 = the faulting instruction's own PC, a6 = where to resume.
h_bsun:
	addq.l	#1,$7000
	moveq	#0,d5
	move.w	6(sp),d5
	sub.l	#$00C0,d5		; format $0, vector 48
	add.l	d5,$7008
	move.l	2(sp),d5
	sub.l	a5,d5
	add.l	d5,$700C
	move.l	a6,2(sp)
	rte

unexp:
	bra.s	unexp
