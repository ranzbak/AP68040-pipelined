; fpureal_dnpacked.s - a PACKED source in a data register is the plain
; F-line on the 68040 (vector 11, format $0, the instruction's own PC) even
; when the opmode is one the FPSP emulates.  WinUAE get_fp_value returns 0
; for Dn with .P on the 040 without asking fault_if_unimplemented_680x0,
; while .X/.D in Dn and every An source ask it first (PLAN.md D22).  cputest
; on the board (board run 2, 28 instructions such as fint.p d0,fp1 and
; facos.p d0,fp1): format $2 with the next PC instead.
;
; The F-line handler stores the format/vector word and the stacked PC.
;   1  fint.p  d0,fp1   FPSP opmode, .P in Dn   -> $002C, own PC
;   2  facos.p d0,fp1   FPSP opmode, .P in Dn   -> $002C, own PC
;   3  fabs.p  d0,fp1   hardware opmode         -> $002C, own PC (unchanged)
;   4  fint.x  d0,fp1   FPSP opmode, .X in Dn   -> $202C, NEXT PC (unchanged:
;                       the unimplemented route still wins there)
;
; diff: --cycles 60000
v_flin	equ	h_fline
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
	lea	$7000,a5
	moveq	#3,d0
c1:	dc.w	$F200,$4C81		; fint.p d0,fp1
	nop
c2:	dc.w	$F200,$4C9C		; facos.p d0,fp1
	nop
c3:	dc.w	$F200,$4C98		; fabs.p d0,fp1
	nop
c4:	dc.w	$F200,$4881		; fint.x d0,fp1
	nop
	bra.s	halt

; F-line: record format/vector and stacked PC.  A format $0 frame stacks the
; instruction's own PC, so step over its 4 bytes; a format $2 frame already
; stacks the next one.  RTE pops either frame by its format.
h_fline:
	move.w	6(sp),(a5)+
	move.w	#0,(a5)+
	move.l	2(sp),(a5)+
	cmpi.w	#$002C,6(sp)
	bne.s	hf_out
	addq.l	#4,2(sp)
hf_out:	rte

unexp:
	bra.s	unexp

halt:
	bra.s	halt
