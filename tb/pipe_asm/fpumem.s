; fpumem.s - plan M10.1(b): the 96-bit operand path.
;
; A floating-point memory operand is 1, 2, 4, 8 or 12 bytes, so up to three
; longword beats on the bus, assembled LEFT ALIGNED because that is what the
; unit's din window wants; an immediate source is in the instruction stream
; and takes no bus access at all; and the (An)+ / -(An) update is by the
; WHOLE operand, once.  Everything here runs against the stub unit
; (tb/tb_fpu_stub.v), whose wide formats round-trip byte for byte and whose
; integer formats round-trip by value.
;
; What each case would catch:
;   1-2  a 12-byte load and store: the beat count, the order and the
;        alignment.  A dropped or swapped beat changes the bytes at $5100.
;   3    8 bytes, the two-beat case.
;   4    a 2-byte load and a 4-byte store: the two lengths differ, so the
;        operand length cannot come from the instruction's size field.
;   5    (An)+ steps by the OPERAND, once: A0 advances 12 + 8 + 2 + 12.
;   6    -(An) with a 12-byte operand, and with a ONE-byte one on A7, where
;        the byte rule makes the step 2 (lib/AP68040 S_FPU_AN's adj).
;   7    an immediate source: `noread` on its words fails the run if the core
;        ever reads them as data instead of taking them from the instruction
;        stream, which is what a 68040 does (lib/AP68040 S_FPU_IMM).
;   8    a 12-byte immediate.
;   9    the (An)+ update STANDS when the unit answers `unimp`, and the
;        frame's address field is the OPERAND's address (PLAN.md D19).
;
; diff: --cycles 60000
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
	movea.l	#$5000,a0		; the source operands
	movea.l	#$5100,a1		; where the round trips are written

;------------------------------------- 1, 2: twelve bytes, three beats
	dc.w	$F218,$4800		; FMOVE.X (A0)+,FP0
	dc.w	$F219,$6800		; FMOVE.X FP0,(A1)+

;------------------------------------- 3: eight bytes, two beats
	dc.w	$F218,$5480		; FMOVE.D (A0)+,FP1
	dc.w	$F219,$7480		; FMOVE.D FP1,(A1)+

;------------------------------------- 4: two bytes in, four out
	dc.w	$F218,$5100		; FMOVE.W (A0)+,FP2
	dc.w	$F219,$6100		; FMOVE.L FP2,(A1)+

;------------------------------------- 6: the predecrement forms
	movea.l	#$520C,a2
	dc.w	$F222,$4B00		; FMOVE.X -(A2),FP6   -- A2 = $5200
	dc.w	$F219,$6B00		; FMOVE.X FP6,(A1)+
	movea.l	sp,a3
	dc.w	$F227,$5B80		; FMOVE.B -(A7),FP7   -- the step is 2, not 1
	move.l	a3,d5
	sub.l	sp,d5
	movea.l	a3,sp

;------------------------------------- 7: an immediate long source
i32:	dc.w	$F23C,$4200,$1234,$5678	; FMOVE.L #$12345678,FP4
	dc.w	$F200,$6200		; FMOVE.L FP4,D0
	move.l	d0,d2			; (the handler below clobbers D0)

;------------------------------------- 8: a twelve-byte immediate source
i96:	dc.w	$F23C,$4A80
	dc.w	$4001,$8000,$0000,$0000,$0000,$0000
	dc.w	$F219,$6A80		; FMOVE.X FP5,(A1)+

;------------------------------------- 9: unimp, with the update standing
	movea.l	a0,a4			; the operand address the frame must carry
	lea	c9e(pc),a5
	lea	c9e(pc),a3
	move.l	#$202C,d7		; format $2, vector 11
c9:	dc.w	$F218,$480E		; FSIN.X (A0)+,FP0 -- not in the unit
c9e:
	move.l	a0,d6

halt:
	bra.s	halt

;--------------------------------------------------------------- handler
; a3 = where to resume, a4 = expected address field, a5 = expected stacked
; PC, d7 = expected format/vector word.  Clobbers d0, d1 and a6.
h_frame:
	movea.l	sp,a6
	moveq	#0,d0
	move.w	6(a6),d0
	sub.l	d7,d0
	move.l	d0,$7000		; format/vector delta
	move.l	2(a6),d0
	sub.l	a5,d0
	move.l	d0,$7004		; stacked-PC delta
	move.l	8(a6),d0
	sub.l	a4,d0
	move.l	d0,$7008		; address-field delta
	move.l	a3,2(a6)		; resume past the instruction
	rte

unexp:
	bra.s	unexp

;--------------------------------------------------------------- operands
	org	$5000
	dc.w	$1111,$2222,$3333,$4444,$5555,$6666	; case 1: twelve bytes
	dc.w	$AAAA,$BBBB,$CCCC,$DDDD			; case 3: eight
	dc.w	$1234					; case 4: two
	dc.w	$0F0F,$1E1E,$2D2D,$3C3C,$4B4B,$5A5A	; case 9's operand, read and dropped

	org	$5200
	dc.w	$7777,$8888,$9999,$AAAA,$BBBB,$CCCC	; case 6: -(A2) from $520C
