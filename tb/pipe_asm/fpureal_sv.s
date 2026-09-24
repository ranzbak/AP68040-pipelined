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
v_flin	equ	h_unimp
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
	clr.l	$700C			; unimplemented instructions taken
	clr.l	$7014			; mismatches in the frame round trip
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

;------------------------------------- 6: the $4130 frame IS installable now
; (M10.7): FRESTORE accepts it and A0 steps by the whole 52 bytes, not 4.
	dc.w	$F358			; FRESTORE (A0)+      -- $41300000

;------------------------------------- 7: the $4160 BUSY frame is installed
; too since the M10 remainder (2026-09-24): no format error, and A0 steps by
; the whole 100 bytes (fpureal_busy.s tests its contents and the resume)
	movea.l	#c7e,a6
	movea.l	#c7,a5
c7:	dc.w	$F358			; FRESTORE (A0)+      -- $41600000
c7e:

;------------------------------------- 8: the round trip that matters.  An
; unimplemented instruction leaves a state in the unit; FSAVE must EXTRACT it
; as the thirteen-longword $4130 frame, FRESTORE must put it back, and a
; second FSAVE must then produce the same thirteen longwords.  The comparison
; is done by the program, so the expect file needs to know nothing about the
; payload's meaning -- only that saving, restoring and saving again is an
; identity.
	movea.l	#$5400,a2		; the first frame
	movea.l	#$5440,a3		; the second
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F200,$000E		; FSIN.X FP0 -- not in hardware: unimp
	dc.w	$F312			; FSAVE    (A2)
	dc.w	$F352			; FRESTORE (A2)
	dc.w	$F313			; FSAVE    (A3)
	; 9: the state was EXTRACTED, not copied -- a third FSAVE with no
	; FRESTORE in between finds nothing to save and writes the IDLE frame
	movea.l	#$5480,a4
	dc.w	$F314			; FSAVE    (A4)
	movea.l	#$5400,a2
	movea.l	#$5440,a3
	moveq	#12,d6
cmpf:	move.l	(a2)+,d2
	cmp.l	(a3)+,d2
	beq.s	cmpf1
	addq.l	#1,$7014
cmpf1:	dbra	d6,cmpf

;------------------------------------- 10: FMOVECR has NO effective address at
; all, and the 68040 reports it as an unimplemented instruction so the FPSP
; can supply the constant (lib/AP68040 S_FPU_DEC's 3'b010 arm, and t_fpu.s
; test 44).  It must reach the unit rather than be faked in the decoder,
; because the unit also captures the state frame a following FSAVE extracts.
	dc.w	$F200,$5C80		; FMOVECR #$00,FP1
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a5 = the faulting instruction's own PC, a6 = where to resume.
h_unimp:
	addq.l	#1,$700C
	move.w	6(sp),d2
	move.l	d2,$7018		; the frame word of the LAST unimp
	move.l	2(sp),$701C		; ... and its stacked PC
	rte

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
	dcb.l	12,0			; ... and its payload
	dc.l	$41600000		; the 100-byte BUSY frame
	dcb.l	24,0			; ... and its payload (CU_SAVEPC 0: no resume)
