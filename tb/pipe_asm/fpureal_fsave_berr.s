; fpureal_fsave_berr.s - audit 2026-09-27, finding 3: FSAVE must not give up
; the unit's state before the frame is really in memory (M68040UM 9.8).  The
; acknowledge went out when the LAST frame store was dispatched; if that
; store then faulted and FSAVE restarted, the unit had already discarded the
; state and the restart wrote an IDLE frame.
;
; Bus mode only: the bench rejects the FIRST write of the armed address.
;   1  FSIN leaves an unimplemented-instruction state (the $4130 frame);
;      FSAVE (A2) takes a write fault on the frame's last longword; after the
;      handler (which completes a pending WB1 write), the frame at $5400 is
;      the $4130 frame -- header $41300000
;   2  the same state again, saved without a fault at $5500: the two frames
;      are identical (13 longwords)
;   3  the state was extracted once: FSAVE again writes the IDLE frame
;   4  (final review I2) a YOUNGER instruction's store fault that restarts
;      it (MOVEM, CM) must not cost the FSAVE its acknowledge: the FSAVE after
;      it writes IDLE, not the same $4130 frame again
;
; expect-berr: 5430 w 5714 w
; diff: --cycles 150000
v_flin	equ	h_unimp
v_fpun	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
v_berr	equ	h_berr
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; unimps taken
	clr.l	$7004			; bus errors taken
	clr.l	$7008			; frame mismatches
	movea.l	#$5400,a2
	fmove.l	#1,fp0
	dc.w	$F200,$000E		; FSIN.X FP0 -- unimplemented
	dc.w	$F312			; FSAVE (A2) -- the last longword faults
	movea.l	#$5480,a4
	dc.w	$F314			; FSAVE (A4) -- extracted: IDLE
	fmove.l	#1,fp0
	dc.w	$F200,$000E		; the same state again
	movea.l	#$5500,a3
	dc.w	$F313			; FSAVE (A3) -- no fault
	movea.l	#$5400,a2
	movea.l	#$5500,a3
	moveq	#12,d6
cmp:	move.l	(a2)+,d2
	cmp.l	(a3)+,d2
	beq.s	cmp1
	addq.l	#1,$7008
cmp1:	dbra	d6,cmp
	move.l	#$AAAA0001,d0
	move.l	#$AAAA0002,d1
	movea.l	#$5600,a5
	fmove.l	#1,fp0
	dc.w	$F200,$000E		; 4: a state again
	dc.w	$F315			; FSAVE (A5) -- no fault
	movem.l	d0-d1,($5710).l		; right behind it; the second longword faults: CM, restart
	movea.l	#$5680,a4
	dc.w	$F314			; FSAVE (A4) -- IDLE: the state went to $5600
halt:	bra.s	halt

h_unimp:
	addq.l	#1,$7000
	rte				; format $2: the next instruction

h_berr:
	movem.l	d7/a5,-(sp)
	addq.l	#1,$7004
	move.w	$1A(sp),d7		; WB1S
	btst	#7,d7
	beq.s	.nwb
	movea.l	$30(sp),a5		; WB1A
	move.l	$34(sp),(a5)		; WB1D: the handler completes the write
.nwb:	movem.l	(sp)+,d7/a5
	rte

unexp:	bra.s	unexp
