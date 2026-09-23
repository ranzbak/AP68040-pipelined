; fpureal_mvm.s - plan M10.4: FMOVEM of the floating-point registers,
; opclass 110/111, twelve bytes each, against the real ap040_fpu.
;
; Three things are checked, and they are checked against different kinds of
; authority, which is why they are separate cases:
;   1  the ROUND TRIP a compiler emits -- save with -(An), restore with
;      (An)+ -- must give the registers back.  That is a property, not a
;      layout, and it holds only if the two mask conventions and the two
;      walk directions agree with each other.
;   2  a control-mode store with the POSTINCREMENT convention: the layout
;      the manual states (M68000PRM FMOVEM: "the first register is
;      transferred ... with successive registers located up through higher
;      addresses", mask bit 7 = FP0), so FP0, FP1, FP2 in order.
;   3  a control-mode store with the PREDECREMENT convention, which is the
;      68040's quirk (PLAN.md D21, lib/AP68040's fp_mvm citing WinUAE
;      fmovem2mem): the mask is read the other way round, so the registers
;      come out FP2, FP1, FP0, AND each register's three longwords are
;      written in REVERSED order because the convention disagrees with the
;      address direction.  Nothing but that rule produces this layout.
;
; diff: --cycles 120000
v_flin	equ	h_fl
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
	movea.l	#$5200,a1		; the -(A1) block grows down from here
	movea.l	#$5300,a2		; case 3
	movea.l	#$5100,a3		; where the round trip is written out
	movea.l	#$5400,a4		; case 2

	dc.w	$F23C,$4000,$0000,$0001	; FMOVE.L #1,FP0   -- 1.0
	dc.w	$F23C,$4080,$0000,$0002	; FMOVE.L #2,FP1   -- 2.0
	dc.w	$F23C,$4100,$0000,$0003	; FMOVE.L #3,FP2   -- 3.0

;------------------------------------- 2, 3: the two control-mode layouts
	dc.w	$F214,$F0E0		; FMOVEM.X FP0-FP2,(A4)  -- postinc convention
	dc.w	$F212,$E007		; FMOVEM.X FP0-FP2,(A2)  -- predec convention

;------------------------------------- 1: save, clobber, restore
	dc.w	$F221,$E007		; FMOVEM.X FP0-FP2,-(A1)
	dc.w	$F23C,$4000,$0000,$0000	; FMOVE.L #0,FP0
	dc.w	$F23C,$4080,$0000,$0000	; FMOVE.L #0,FP1
	dc.w	$F23C,$4100,$0000,$0000	; FMOVE.L #0,FP2
	dc.w	$F219,$D0E0		; FMOVEM.X (A1)+,FP0-FP2
	dc.w	$F21B,$6800		; FMOVE.X FP0,(A3)+
	dc.w	$F21B,$6880		; FMOVE.X FP1,(A3)+
	dc.w	$F21B,$6900		; FMOVE.X FP2,(A3)+

;------------------------------------- 4, 5, 6: the effective-address rules.
; A store rejects (An)+ and the PC-relative modes, a load rejects -(An), and
; each rejection is the ordinary F-line: vector 11, format $0, the
; instruction's own PC (PLAN.md D21).
	clr.l	$7000			; traps taken
	clr.l	$7004			; format/vector delta
	clr.l	$7008			; own-PC delta
	movea.l	#c4e,a6
	movea.l	#c4,a5
c4:	dc.w	$F221,$D0E0		; FMOVEM.X -(A1),FP0-FP2   -- a load may not
c4e:
	movea.l	#c5e,a6
	movea.l	#c5,a5
c5:	dc.w	$F219,$F0E0		; FMOVEM.X FP0-FP2,(A1)+   -- a store may not
c5e:
	movea.l	#c6e,a6
	movea.l	#c6,a5
c6:	dc.w	$F23A,$F0E0,$0000	; FMOVEM.X FP0-FP2,(d16,PC) -- nor PC-relative
c6e:
halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a5 = the faulting instruction's own PC, a6 = where to resume.
h_fl:
	addq.l	#1,$7000
	moveq	#0,d2
	move.w	6(sp),d2
	sub.l	#$002C,d2		; format $0, vector 11
	add.l	d2,$7004
	move.l	2(sp),d2
	sub.l	a5,d2
	add.l	d2,$7008
	move.l	a6,2(sp)
	rte

unexp:
	bra.s	unexp
