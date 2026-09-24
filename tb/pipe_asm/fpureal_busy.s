; fpureal_busy.s - the $4160 BUSY state frame (plan M10 remainder, 2026-09-24).
;
; The FPSP needs it for every unsupported data type (vector 55: denormals,
; packed decimal): its handler FSAVEs the state the unit prepared, and on the
; way out it FRESTOREs a BUSY frame it built itself -- with CU_SAVEPC = $FE
; when the instruction is to be COMPLETED by the hardware from the operands
; it left in ETEMP/FPTEMP (res_func.sa fix_stk, gen_except.sa do_clean).
; Before this, FSAVE wrote such a state as the 52-byte $4130 frame and
; FRESTORE refused $41600000 with the format error, so 68040.library's FPSP
; took vector 14 on its first denormal (tb/fpsp_asm/fpsp_lib.s found it).
;
; The layout is lib/AP68040's fsave_busy_word (WinUAE's 68040 fpuop_save
; order, the offsets Motorola's fpsp.h uses from the top of the frame).
; What each case would catch:
;   1  a datatype fault (FADD.X of an extended denormal from memory): the
;      handler's FSAVE writes 25 longwords, checked ABSOLUTELY -- header,
;      FPIARCU (the FADD's PC), CMDREG1B/CMDREG3B, the tags, FPTEMP (the
;      destination, 1.0) and ETEMP (the denormal) -- and the frame word is
;      vector 55 / format $3 with the next PC and the operand's EA.
;   2  FRESTORE (A2) puts it back; FSAVE -(A7) walks A7 down by 100, FRESTORE
;      (A7)+ back up by 100, and FSAVE (A3) writes the same 25 longwords.
;   3  a hand-built BUSY frame with CU_SAVEPC = $FE and FADD FP?,FP2: the
;      unit completes the command FROM THE FRAME (FPTEMP 2.25 + ETEMP 1.5)
;      into FP2, which held 7.0 -- and the store right behind the FRESTORE
;      must wait for it (the released-operation interlock).
;   4  the same with FMUL, ETEMP an extended denormal as the FPSP normalizes
;      it (exponent $7FC9, the ETE15 flag set) and FPTEMP 2^108: FP3 =
;      2^-16330.  The denormal $0000_0000000000000100 is 2^8 x 2^-16446 on a
;      68040 -- Motorola's extended format reads exponent 0 as -16383 with
;      the explicit integer bit, not x87's -16382 -- and that is also the
;      FPSP's own convention: nrm_set subtracts the shift count from the
;      exponent field 0, giving -55 = $7FC9 with ETE15.  So 2^-16438 x
;      2^108 = 2^-16330, biased $0035.
;   5  FMOVE.P from memory (packed decimal, the other datatype fault): the
;      twelve operand bytes split across ETEMP and FPTEMP the way the 68040
;      stores them (FPSP get_op copies the first longword back from FPTEMP_LO
;      before decbin), with STAG 7 and E1.
;   6  FADD.S of a single denormal and 7 FMUL.D of a negative double
;      denormal: ETEMP holds the fraction UNNORMALIZED under the exponent
;      word WinUAE writes for them ($3F80 / $3C00), which is what the FPSP's
;      src_sd_dnrm expects -- it rewrites the exponent with its own bias
;      ($3F81 / $3C01) and normalizes, so the mantissa must be 0.fraction;
;      the raw memory image the unit used to leave there lost the single's
;      fraction entirely (68040.library found it: 2^-127 came back as a
;      negative unnormal).  STAG 5, and the sign stays in ETEMP_EX.
;   8  a DEFERRED exception (INEX2 enabled, a released FDIV) is pending when
;      an FRESTORE of the NULL frame arrives: the FRESTORE replaces the state
;      wholesale and the exception goes with it -- it is not taken in front
;      of the FRESTORE (lib/AP68040 S_FREST1), nor after it.
;
; diff: --cycles 150000
v_flin	equ	unexp
v_fpun	equ	h_uns
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
v_fparith equ	h_arith
	include	"vectors.inc"

	org	$400
start:
	clr.l	$7000			; datatype faults taken
	clr.l	$7004			; mismatches in the BUSY round trip
	clr.l	$7008			; the last frame word
	clr.l	$7020			; arithmetic exceptions taken
	dc.w	$F23C,$4080,$0000,$0001	; FMOVE.L #1,FP1
	movea.l	#$5400,a2		; where the handler saves the frame
	bra.w	c1

;------------------------------------- 1: the datatype fault's BUSY frame
	org	$500
c1:	dc.w	$F239,$48A2,$0000,$5000	; FADD.X $5000,FP1   -- a denormal source
c1e:

;------------------------------------- 2: round trip, and the (An) steps
	dc.w	$F352			; FRESTORE (A2)
	move.l	sp,d3
	dc.w	$F327			; FSAVE    -(A7)
	move.l	sp,d4			; 100 lower
	dc.w	$F35F			; FRESTORE (A7)+
	move.l	sp,d5			; back again
	movea.l	#$5480,a3
	dc.w	$F313			; FSAVE    (A3)
	movea.l	#$5400,a2
	moveq	#24,d6
cmpf:	move.l	(a2)+,d2
	cmp.l	(a3)+,d2
	beq.s	cmpf1
	addq.l	#1,$7004
cmpf1:	dbra	d6,cmpf

;------------------------------------- 3: CU_SAVEPC = $FE resumes the command
	dc.w	$F23C,$4100,$0000,$0007	; FMOVE.L #7,FP2
	movea.l	#$5100,a4
	dc.w	$F354			; FRESTORE (A4)       -- FADD 1.5 to 2.25 -> FP2
	dc.w	$F239,$6900,$0000,$5500	; FMOVE.X FP2,$5500

;------------------------------------- 4: ... with an ETE15-extended operand
	movea.l	#$5200,a4
	dc.w	$F35C			; FRESTORE (A4)+      -- FMUL 2^108 by the denormal -> FP3
	move.l	a4,d7			; +100
	dc.w	$F239,$6980,$0000,$550C	; FMOVE.X FP3,$550C

;------------------------------------- 5: a packed-decimal source
	movea.l	#$5600,a2
	dc.w	$F239,$4C80,$0000,$5300	; FMOVE.P $5300,FP1

;------------------------------------- 6, 7: single and double denormals
	movea.l	#$5700,a2
	dc.w	$F23C,$44A2,$0040,$0000	; FADD.S #$00400000,FP1  -- 2^-127
	movea.l	#$5780,a2
	dc.w	$F23C,$54A3,$8000,$0000,$0000,$0001	; FMUL.D #-2^-1074,FP1

;------------------------------------- 8: FRESTORE discards a pending exception
	dc.w	$F23C,$9000,$0000,$0200	; FMOVE.L #$0200,FPCR  -- INEX2 enabled
	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0
	dc.w	$F23C,$4080,$0000,$0003	; FMOVE.L #3,FP1
	dc.w	$F200,$0420		; FDIV    FP1,FP0   -- released, then INEX2
	moveq	#1,d0
	add.l	d0,d0			; integer work while it runs
	movea.l	#$5800,a4
	dc.w	$F354			; FRESTORE (A4)       -- NULL
	dc.w	$F23C,$4180,$0000,$0007	; FMOVE.L #7,FP3     -- no trap here either
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; vector 55: record the frame, extract the unit's state, return past the
; instruction (format $3 stacks the NEXT instruction's PC)
h_uns:
	addq.l	#1,$7000
	move.w	6(sp),$7008+2		; the frame word
	move.l	2(sp),$700C		; the stacked PC
	move.l	8(sp),$7010		; the effective address
	dc.w	$F312			; FSAVE (A2)
	rte

h_arith:
	addq.l	#1,$7020
	rte

unexp:
	bra.s	unexp

;--------------------------------------------------------------- data
	org	$5000
	dc.l	$00000000,$00000000,$00000100	; an extended denormal, 2^-16438 on a 68040

	org	$5100			; 3: FADD, CU_SAVEPC $FE, FPTEMP 2.25, ETEMP 1.5
	dc.l	$41600000,$00000000,$FE000000
	dcb.l	13,0
	dc.l	$01220000		; 16 CMDREG1B: opclass 000, FPn = FP2, FADD
	dc.l	0,0			; 17, 18
	dc.l	$40000000,$90000000,$00000000	; 19-21 FPTEMP 2.25
	dc.l	$3FFF0000,$C0000000,$00000000	; 22-24 ETEMP 1.5

	org	$5200			; 4: FMUL, ETE15, FPTEMP 2^108, ETEMP the denormal
	dc.l	$41600000,$00000000,$FE000000
	dcb.l	12,0
	dc.l	$10000000		; 15 STAG 0, ETE15
	dc.l	$01A30000		; 16 CMDREG1B: FPn = FP3, FMUL
	dc.l	0,0
	dc.l	$406B0000,$80000000,$00000000	; 19-21 FPTEMP 2^108
	dc.l	$7FC90000,$80000000,$00000000	; 22-24 ETEMP 2^-16438, normalized

	org	$5300			; 5: 1.25E+2, packed decimal
	dc.l	$00020001,$25000000,$00000000

	org	$5800			; 8: the NULL frame
	dc.l	$00000000
