; fpureal.s - plan M10.1 step 3: the FIRST program to run against the REAL
; ap040_fpu instead of tb/tb_fpu_stub.v.
;
; The stub round-tripped bytes and integers, so it could say nothing about
; floating point and everything about sequencing.  This one is the mirror:
; every expected value is an IEEE bit pattern computed by hand (with
; python3 Fraction, exactly-rounded, round-to-nearest-even -- the reset
; state of FPCR), so it fails loudly if the operand window is misaligned,
; if a conversion or the rounding is wrong, or if the interlock releases
; the instruction before the unit has the result.
;
; FPCR is left at its reset value throughout -- enables all zero -- because
; the arithmetic-exception port (exc_req/exc_vec) is not wired yet (plan
; M10.1 step (d)), so an ENABLED arithmetic exception would be silently
; dropped.  Nothing here can raise one: every operand is a small exact
; binary value and the one inexact result (1/3) sets the INEX bits only.
;
; What each case would catch:
;   1     a 12-byte extended load and store through the real unit: the
;         96-bit window's alignment.  2.0 and 3.0 in, 5.0 out.
;   2-4   FADD / FSUB / FMUL with exact results: the arithmetic dispatch
;         and the register file, and (FMUL, FDIV) the RELEASE, because
;         those are the ops for which `accepted` rises before `done`.
;   5     FDIV 1.0 / 3.0 = the one inexact result: the extended mantissa
;         is ...AAAB, i.e. rounded UP, so a truncating path is visible.
;         Integer instructions sit between the divide and the store, so
;         the store's stall is what makes the value right.
;   6-7   the same value stored as single and as double: two different
;         roundings of one register, which is the pack path.
;   8-9   single and double SOURCES converted to extended.
;   10-12 the integer conversions both ways, including a negative.
;   13    FPIAR: written on every dispatch that engages the unit.  No
;         instruction can read it until opclass 100/101 is decoded, so
;         the bench reads it hierarchically and the last FP instruction
;         is placed at a fixed address for it (`org $700`).
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
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$5000,a0		; the operands
	movea.l	#$5100,a1		; where the results are written

;------------------------------------- the two extended operands
	dc.w	$F218,$4800		; FMOVE.X (A0)+,FP0    -- 2.0
	dc.w	$F218,$4880		; FMOVE.X (A0)+,FP1    -- 3.0

;------------------------------------- 1, 2: FP2 = 2.0 + 3.0 = 5.0
	dc.w	$F200,$0100		; FMOVE   FP0,FP2
	dc.w	$F200,$0522		; FADD    FP1,FP2
	dc.w	$F219,$6900		; FMOVE.X FP2,(A1)+

;------------------------------------- 3: FP3 = 3.0 - 2.0 = 1.0
	dc.w	$F200,$0580		; FMOVE   FP1,FP3
	dc.w	$F200,$01A8		; FSUB    FP0,FP3
	dc.w	$F219,$6980		; FMOVE.X FP3,(A1)+

;------------------------------------- 4: FP4 = 2.0 * 3.0 = 6.0
	dc.w	$F200,$0200		; FMOVE   FP0,FP4
	dc.w	$F200,$0623		; FMUL    FP1,FP4
	dc.w	$F219,$6A00		; FMOVE.X FP4,(A1)+

;------------------------------------- 5: FP5 = 3.0 / 2.0 = 1.5
	dc.w	$F200,$0680		; FMOVE   FP1,FP5
	dc.w	$F200,$02A0		; FDIV    FP0,FP5
	dc.w	$F219,$6A80		; FMOVE.X FP5,(A1)+

;------------------------------------- 6: FP6 = 1.0 / 3.0, the inexact one
	dc.w	$F23C,$4300,$0000,$0001	; FMOVE.L #1,FP6
	dc.w	$F200,$0720		; FDIV    FP1,FP6
	; integer work while the divide runs in the background: the store
	; below is the instruction that must wait for it
	moveq	#3,d4
	add.l	d4,d4
	add.l	d4,d4
	add.l	d4,d4
	dc.w	$F219,$6B00		; FMOVE.X FP6,(A1)+
	dc.w	$F219,$6700		; FMOVE.S FP6,(A1)+
	dc.w	$F219,$7700		; FMOVE.D FP6,(A1)+

;------------------------------------- 8, 9: single and double sources
	dc.w	$F218,$4780		; FMOVE.S (A0)+,FP7    -- 1.5
	dc.w	$F219,$6B80		; FMOVE.X FP7,(A1)+
	dc.w	$F218,$5780		; FMOVE.D (A0)+,FP7    -- 0.25
	dc.w	$F219,$6B80		; FMOVE.X FP7,(A1)+

;------------------------------------- 10, 11, 12: the integer conversions
	dc.w	$F23C,$4000,$0000,$0064	; FMOVE.L #100,FP0
	dc.w	$F200,$6000		; FMOVE.L FP0,D0
	dc.w	$F23C,$4080,$FFFF,$FFFE	; FMOVE.L #-2,FP1
	dc.w	$F201,$6080		; FMOVE.L FP1,D1
	dc.w	$F219,$6880		; FMOVE.X FP1,(A1)+
	dc.w	$F23C,$5100,$FFFD	; FMOVE.W #-3,FP2
	dc.w	$F202,$7100		; FMOVE.W FP2,D2

;------------------------------------- 13: FPIAR at a known address
	bra	lastfp			; (the gap to $700 is not code)
	org	$700
lastfp:	dc.w	$F200,$0380		; FMOVE   FP0,FP7
halt:
	bra.s	halt

unexp:
	bra.s	unexp

;--------------------------------------------------------------- operands
	org	$5000
	dc.l	$40000000,$80000000,$00000000	; 2.0   extended
	dc.l	$40000000,$C0000000,$00000000	; 3.0   extended
	dc.l	$3FC00000			; 1.5   single
	dc.l	$3FD00000,$00000000		; 0.25  double
