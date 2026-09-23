; fpureal_sv.s - plan M10.5: FSAVE and FRESTORE, the NULL and IDLE frames.
;
; One longword each way (lib/AP68040 S_FSAVE1 / S_FREST2):
;   FSAVE writes $00000000 when the unit has never been used and
;   $41000000 once it has; FRESTORE of a version byte 0 resets the unit and
;   of $41000000 makes it idle-but-used.  A frame this core cannot install
;   -- the $4130 and $4160 payloads -- takes the FORMAT ERROR, vector 14
;   with format $0 and the instruction's own PC, which is the reference's
;   default arm.  Refusing loudly beats accepting a state we cannot build.
;
; What each case would catch:
;   1  FSAVE before any floating-point instruction: the NULL frame.  This is
;      the case Kickstart's probe at $F80DA4 runs, and the one that decides
;      whether AmigaOS believes there is an FPU.
;   2  after an FMOVE the unit is used, so FSAVE writes the IDLE frame.
;   3  FRESTORE of the NULL frame resets the unit -- and the proof is that
;      FSAVE then writes NULL again, which it would not if `fp_reset` had
;      not reached the unit.
;   4  FRESTORE of the IDLE frame: used again, so FSAVE writes $41000000.
;   5  -(A7) and (A7)+ round trip: FSAVE steps A7 down by four, FRESTORE
;      back up.
;   6  FRESTORE of a $41300000 frame -- a legal 68040 frame this core does
;      not sequence -- takes vector 14, checked as deltas.
;
; diff: --cycles 120000
v_flin	equ	unexp
v_fpun	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	h_fmt
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; format errors taken
	clr.l	$7004			; format/vector delta
	clr.l	$7008			; own-PC delta
	movea.l	#$5100,a1		; where the frames are written
	movea.l	#$5000,a0		; the frames that are restored

;------------------------------------- 1: NULL, before anything else
	dc.w	$F311			; FSAVE   (A1)
	addq.l	#4,a1

;------------------------------------- 2: used, so IDLE
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F311			; FSAVE   (A1)
	addq.l	#4,a1

;------------------------------------- 3: FRESTORE NULL resets the unit
	dc.w	$F358			; FRESTORE (A0)+      -- $00000000
	dc.w	$F311			; FSAVE    (A1)       -- NULL again
	addq.l	#4,a1

;------------------------------------- 4: FRESTORE IDLE marks it used
	dc.w	$F358			; FRESTORE (A0)+      -- $41000000
	dc.w	$F311			; FSAVE    (A1)       -- IDLE again
	addq.l	#4,a1

;------------------------------------- 5: the stack forms
	move.l	sp,d3
	dc.w	$F327			; FSAVE    -(A7)
	move.l	sp,d4			; four lower
	dc.w	$F35F			; FRESTORE (A7)+
	move.l	sp,d5			; back again

;------------------------------------- 6: a frame this core cannot install
	movea.l	#c6e,a6
	movea.l	#c6,a5
c6:	dc.w	$F358			; FRESTORE (A0)+      -- $41300000
c6e:
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a5 = the faulting instruction's own PC, a6 = where to resume.
h_fmt:
	addq.l	#1,$7000
	moveq	#0,d2
	move.w	6(sp),d2
	sub.l	#$0038,d2		; format $0, vector 14
	add.l	d2,$7004
	move.l	2(sp),d2
	sub.l	a5,d2
	add.l	d2,$7008
	move.l	a6,2(sp)
	rte

unexp:
	bra.s	unexp

;--------------------------------------------------------------- the frames
	org	$5000
	dc.l	$00000000		; NULL
	dc.l	$41000000		; IDLE
	dc.l	$41300000		; the 52-byte unimplemented-state frame
