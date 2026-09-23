; fpureal_exc.s - plan M10.3: the ENABLED arithmetic exceptions, vectors
; 48-54, against the real ap040_fpu.
;
; The 68040 reports an enabled arithmetic exception in one of two shapes,
; and which one depends on whether the core had already released the
; operation to the background when the unit raised it:
;   * still in the pipeline -> POST-instruction, format $0, the NEXT
;     instruction's PC (lib/AP68040 ap040_core.v:4217);
;   * already released -> it cannot be reported against an instruction that
;     has left, so it becomes PENDING and is taken in front of the next
;     floating-point instruction, PRE-instruction, format $0, with THAT
;     instruction's own PC (ap040_core.v:1944 and :3600).  FPIAR still names
;     the one that faulted, which is what the FPSP reads.
;
; Case 1 is written so both shapes give the SAME stacked PC -- the next
; instruction after the divide IS the next floating-point instruction -- so
; it checks the vector and the frame without depending on the unit's
; internal release timing.  Case 2 puts integer work in between, so the two
; shapes give DIFFERENT PCs and the test pins down which one this core
; takes.
;
; What each case would catch:
;   1  DZ enabled, 1.0 / 0.0: vector 50, format $0.  With the exception
;      dropped the divide would simply store an infinity.
;   2  INEX2 enabled on a divide that IS released: the trap must arrive on
;      the LATER floating-point instruction, not on the integer work in
;      between, and the FPU must not be left busy (the fp_bg hang).
;   3  with the enables cleared the same operations run clean, and the
;      register the trap suppressed is written this time.
;
; The handler records deltas against the rule, plus the raw frame words of
; the first trap, so the expect file holds zeros and one known frame.
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
v_fparith equ	h_fpe
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; traps taken
	clr.l	$7004			; format/vector delta
	clr.l	$7008			; stacked-PC delta
	clr.l	$700C			; the first trap's raw format/vector word
	clr.l	$7010			; ... and its raw stacked PC
	movea.l	#$5100,a1		; where the results are written

;------------------------------------- 1: divide by zero, DZ enabled
	dc.w	$F23C,$9000,$0000,$0400	; FMOVE.L #$0400,FPCR  -- DZ enabled
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F23C,$4080,$0000,$0000	; FMOVE.L #0,FP1
	move.l	#$00C8,d7		; format $0, vector 50 (DZ)
	movea.l	#c1e,a3			; the same PC either way (see above)
c1:	dc.w	$F200,$0420		; FDIV    FP1,FP0
c1e:	dc.w	$F23C,$4100,$0000,$0002	; FMOVE.L #2,FP2

;------------------------------------- 2: INEX2 enabled on a released op
	dc.w	$F23C,$9000,$0000,$0200	; FMOVE.L #$0200,FPCR  -- INEX2 enabled
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F23C,$4080,$0000,$0003	; FMOVE.L #3,FP1
	move.l	#$00C4,d7		; format $0, vector 49 (INEX)
	movea.l	#c2b,a3			; the LATER floating-point instruction
c2:	dc.w	$F200,$0420		; FDIV    FP1,FP0   -- inexact
	moveq	#1,d3
	add.l	d3,d3
	add.l	d3,d3			; integer work runs on
c2b:	dc.w	$F23C,$4180,$0000,$0007	; FMOVE.L #7,FP3
c2e:

;------------------------------------- 3: the enables cleared, no traps
	dc.w	$F23C,$9000,$0000,$0000	; FMOVE.L #0,FPCR
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F200,$0420		; FDIV    FP1,FP0   -- 1/3, still inexact
	dc.w	$F219,$6800		; FMOVE.X FP0,(A1)+
	dc.w	$F219,$6900		; FMOVE.X FP2,(A1)+
	dc.w	$F219,$6980		; FMOVE.X FP3,(A1)+
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; d7 = the expected format/vector word, a3 = the expected stacked PC.
h_fpe:
	addq.l	#1,$7000
	moveq	#0,d2
	move.w	6(sp),d2
	tst.l	$7000
	move.l	d2,d1
	sub.l	d7,d1
	add.l	d1,$7004
	move.l	2(sp),d1
	sub.l	a3,d1
	add.l	d1,$7008
	cmpi.l	#1,$7000		; keep the FIRST trap's raw frame
	bne.s	h_ret
	move.l	d2,$700C
	move.l	2(sp),$7010
h_ret:
	rte

unexp:
	bra.s	unexp
