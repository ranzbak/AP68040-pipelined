; fpustub.s - plan M10.1(a)+(c): the CL_FPU class and the FPU's
; req / accepted / done interlock, against the fixed-latency stub unit
; (tb/tb_fpu_stub.v).  Runs ONLY in the FPU legs of run_pipe_tests.sh, which
; build the core with HAS_FPU = 1 and the stub attached; with HAS_FPU = 0
; every one of these opcodes is M10.0's F-line exception instead, which is
; what fline4.s tests.
;
; What is being checked, and what breaks it:
;   1 a register operand reaches the unit and its answer comes back, through
;     the LEFT-ALIGNED din/dout windows the unit's port uses;
;   2 a long operation releases the instruction at `accepted` and the
;     integer instructions behind it run, but a reader of the result waits
;     for `done` -- if it did not, case 2 would read the OLD value;
;   3 a second FP instruction waits while one is in flight: the stub poisons
;     the destination with $BADBAD00 if the core requests it while busy;
;   4 word and byte formats, in both directions;
;   5 `unimp` (an opmode the unit does not have) -> vector 11, format $2,
;     the NEXT instruction's PC and the faulted instruction's own PC in the
;     address field -- lib/AP68040's go_fp_unimp, PLAN.md D19;
;   6 `unsupp` (an unsupported data type on an opclass 011 store) ->
;     vector 55, format $3, the next PC and a zero address field.
;
; The stub's arithmetic is 32-bit integer on purpose: these are sequencing
; tests and say nothing about floating point.  t_fpu.s is the oracle for
; that, once the real ap040_fpu is wired in.
;
; diff: --cycles 40000
v_flin	equ	h_frame
v_fpun	equ	h_frame
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	movea.l	#$7000,a6

;--------------------------------------------------- 1: load and read back
	move.l	#5,d0
	dc.w	$F200,$4000		; FMOVE.L D0,FP0      (opclass 010, long)
	move.l	#7,d0
	dc.w	$F200,$4080		; FMOVE.L D0,FP1
	dc.w	$F202,$6000		; FMOVE.L FP0,D2      (opclass 011, long)
	move.l	d2,(a6)+		; [$7000] = 5

;------------------------------ 2: a background operation, then a reader of
;   its result.  The four ADDQs are what runs between `accepted` and `done`.
	dc.w	$F200,$0422		; FADD.X FP1,FP0      -> FP0 = 12
	moveq	#1,d3
	addq.l	#1,d3
	addq.l	#1,d3
	addq.l	#1,d3
	dc.w	$F202,$6000		; FMOVE.L FP0,D2      (must see 12, not 5)
	move.l	d2,(a6)+		; [$7004] = 12
	move.l	d3,(a6)+		; [$7008] = 4

;------------------------------------------ 3: two FP operations back to back
	dc.w	$F200,$0422		; FADD.X FP1,FP0      -> 19
	dc.w	$F200,$0422		; FADD.X FP1,FP0      -> 26
	dc.w	$F202,$6000		; FMOVE.L FP0,D2
	move.l	d2,(a6)+		; [$700C] = 26  ($BADBAD00 if the core overlapped them)

;------------------------------------------------- 4: word and byte formats
	move.l	#$12345678,d0
	dc.w	$F200,$5180		; FMOVE.W D0,FP3      -> FP3 = $00005678
	dc.w	$F203,$6180		; FMOVE.L FP3,D3
	move.l	d3,(a6)+		; [$7010] = $00005678
	moveq	#0,d4
	dc.w	$F204,$7980		; FMOVE.B FP3,D4      -> the low byte only
	move.l	d4,(a6)+		; [$7014] = $00000078

;----------------------------------------- 5: unimp -> vector 11, format $2
	lea	c5(pc),a4		; expected address field: the faulted PC
	lea	c5e(pc),a5		; expected stacked PC: the next instruction
	lea	c5e(pc),a1		; where the handler resumes
	move.l	#$202C,d7		; format $2, vector 11
c5:	dc.w	$F200,$040E		; FSIN FP1,FP0 -- not in the unit
c5e:

;----------------------------------------- 6: unsupp -> vector 55, format $3
	move.l	#$FF000001,d0
	dc.w	$F200,$4100		; FMOVE.L D0,FP2 -- the stub's "unsupported" marker
	suba.l	a4,a4			; expected address field: zero (no memory operand)
	lea	c6e(pc),a5
	lea	c6e(pc),a1
	move.l	#$30DC,d7		; format $3, vector 55
c6:	dc.w	$F204,$6100		; FMOVE.L FP2,D4 -- must NOT write D4
c6e:

halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a1 = where to resume, a4 = expected address field, a5 = expected stacked
; PC, d7 = expected format/vector word.  Formats $2 and $3 both carry the
; address field at +8.  Clobbers d0 and a2.
h_frame:
	movea.l	sp,a2
	moveq	#0,d0
	move.w	6(a2),d0
	sub.l	d7,d0
	move.l	d0,(a6)+		; format/vector delta
	move.l	2(a2),d0
	sub.l	a5,d0
	move.l	d0,(a6)+		; stacked-PC delta
	move.l	8(a2),d0
	sub.l	a4,d0
	move.l	d0,(a6)+		; address-field delta
	move.l	a1,2(a2)		; resume past the instruction
	rte

unexp:
	bra.s	unexp
