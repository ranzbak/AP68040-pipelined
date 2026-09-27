; fpureal_mi.s - findings/fpu-fixes/plan.md P1: memory-indirect FP effective
; addresses.
;
; M68040UM 10.7.2's FP timing tables list every memory-indirect mode, and the
; 68881/68882 coprocessor interface takes any control-alterable EA, so
; ([bd,An,Xn],od) and its kin are legal operands for every FP instruction that
; takes a memory operand.  Each case below would take the F-line (vector 11,
; here `unexp`) on a core that refuses them.
;
; What each case would catch:
;   1  a memory-indirect SOURCE: the pointer at $3100 is read, then the word
;      at $3200.  FDIV leaves the unit busy (fp_bg) for case 2.
;   2  a full-format memory-indirect source with index and outer displacement
;      behind a released FDIV: the pointer at A0 + D1*4 = $3004 is $3600, and
;      the operand is at $3600 + 8.
;   3  a memory-indirect DESTINATION (opclass 011 store): the pointer at $3104
;      is read ONCE -- a store decodes with dst = src, and reading both would
;      touch $3104 twice (the readonce line).
;   4  FScc to a memory-indirect byte: one pointer read, one byte write.
;   5  FMOVE of a control register to memory through a pointer.
;   6  FSAVE through a pointer: the IDLE frame, the unit having been used.
;
; diff: --cycles 120000
v_flin	equ	unexp		; any F-line is the failure P1 closes
v_fpun	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	lea	$3000,a0
	moveq	#1,d1
	fmove.l	#10,fp5
	fdiv.w	([$3100.w]),fp5		; 1: 10 / 5 -> fp5 = 2
	fadd.x	([0,a0,d1.l*4],8),fp5	; 2: 2 + 3.0 -> fp5 = 5
	fmove.l	fp5,([$3104.w])		; 3: $3300 = 5
	fsne	([$3108.w])		; 4: 5 <> 0: the byte at $3400 = $FF
	fmove.l	fpcr,([$310c.w])	; 5: $3500 = FPCR = 0
	fsave	([$3110.w])		; 6: $3700 = $41000000 (IDLE)
halt:	bra.s	halt
unexp:	bra.s	unexp

	org	$3004
	dc.l	$3600			; case 2's pointer
	org	$3100
	dc.l	$3200, $3300, $3400, $3500, $3700
	org	$3200
	dc.w	5
	org	$3300
	dc.l	$DEADBEEF
	org	$3400
	dc.l	$00112233
	org	$3500
	dc.l	$DEADBEEF
	org	$3608
	dc.l	$40000000, $C0000000, $00000000	; 3.0 extended
	org	$3700
	dc.l	$DEADBEEF
