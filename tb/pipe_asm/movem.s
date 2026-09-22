; movem.s - plan M4 tb_ap040_pipe_movem: MOVEM both directions, .W/.L,
; -(An) (mask reversed; base in the list stores its initial value minus the
; size, MC68020/30/40: PRM 4-128),
; (An)+ (base in the list: not loaded, gets the incremented address), the
; control modes incl. memory indirect, word loads sign-extended into Dn and
; An, the empty mask, all 16 registers, A7 as the base, a register written
; just before a store, a loaded register used at once (EA and ALU), and
; loads arriving while EX is busy with a divide.
; expect-inimage
; expect-range: 7000 7200
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

setall	macro
	move.l	#$D0D0D000,d0
	move.l	#$D1D1D101,d1
	move.l	#$D2D2D202,d2
	move.l	#$D3D3D303,d3
	move.l	#$D4D4D404,d4
	move.l	#$D5D5D505,d5
	move.l	#$D6D6D606,d6
	move.l	#$D7D7D707,d7
	movea.l	#$A0A0A000,a0
	movea.l	#$A1A1A101,a1
	movea.l	#$A2A2A202,a2
	movea.l	#$A3A3A303,a3
	movea.l	#$A4A4A404,a4
	movea.l	#$A5A5A505,a5
	endm

	org	$400
start:
	setall
	movea.l	#$7040,a6
	; ---- registers to memory, -(An), long, base in the list
	movem.l	d0-d7/a0-a6,-(a6)	; a6 stored as $703C (initial - 4), a6 -> $7004
	move.l	a6,($7100).l
	; ---- word, control mode (d16,An), odd register set
	movea.l	#$7000,a6
	movem.w	d1/d3/a2/a5,$48(a6)	; $7048..$704f
	; ---- empty mask
	dc.w	$48E6,$0000		; movem.l <none>,-(a6): a6 unchanged
	move.l	a6,($7104).l
	; ---- A7 as the base, predecrement (sp = $1F00)
	movem.l	d6/d7,-(sp)
	move.l	sp,($7108).l
	movem.l	(sp)+,d4/d5		; d4 = d6, d5 = d7, sp back
	move.l	sp,($710c).l
	move.l	d4,($7110).l
	move.l	d5,($7114).l
	; ---- memory to registers, (An)+, long, base in the list
	movea.l	#$7004,a6
	movem.l	(a6)+,d0-d7/a0-a6	; a6 not loaded: $7004 + 60 = $7040
	move.l	a6,($7118).l
	move.l	a5,($711c).l
	move.l	d0,($7120).l
	move.l	a0,($7124).l
	; ---- word loads sign-extend into Dn and An
	move.w	#$8001,($7060).l
	move.w	#$7FFE,($7062).l
	move.w	#$FFFF,($7064).l
	movea.l	#$7060,a1
	movem.w	(a1),d2/d3/a3		; control mode (An): a1 unchanged
	move.l	d2,($7128).l
	move.l	d3,($712c).l
	move.l	a3,($7130).l
	move.l	a1,($7134).l
	; ---- absolute, indexed and memory-indirect control modes
	move.l	#$11112222,d1
	move.l	#$33334444,d2
	movem.l	d1/d2,($7070).w
	moveq	#8,d3
	movem.l	d1/d2,(4,a1,d3.w)	; $7060 + 4 + 8 = $706c: overlaps $7070
	move.l	#$7080,($7078).l
	movea.l	#$7070,a2
	movem.l	d1/d2,([8,a2])		; pointer at $7078 -> $7080
	movem.l	([8,a2],4),d6/d7	; $7084, $7088: d6 = $33334444
	move.l	d6,($7138).l
	move.l	d7,($713c).l
	; ---- a register written just before the store; a loaded register used at once
	move.l	#$CAFEF00D,d0
	movem.l	d0,($7090).l
	movea.l	#$7094,a3
	move.l	#$7098,(a3)
	movem.l	(a3),a4			; a4 = $7098
	move.l	#$5A5A5A5A,(a4)		; the loaded base used at once
	movem.l	(a3),d5
	add.l	d5,d5			; ... and in the ALU
	move.l	d5,($7140).l
	; ---- loads arriving while EX divides (the micro-ops wait)
	move.l	#1000000,d1
	moveq	#7,d2
	movea.l	#$7000,a0
	divu.l	d2,d1
	movem.l	(a0)+,d3-d7
	move.l	d1,($7144).l
	move.l	d7,($7148).l
	move.l	a0,($714c).l
	; ---- all 16, word, to memory then back
	setall
	movea.l	#$7180,a6
	move.l	#$A6A6A606,-(sp)
	movem.w	d0-d7/a0-a7,(a6)
	movem.w	(a6),d0-d7/a0-a6
	move.l	(sp)+,d0		; restores sp
	move.l	d7,($7150).l
	move.l	a5,($7154).l
	move.l	a6,($7158).l
halt:
	bra.s	halt
unexp:
	bra.s	unexp
