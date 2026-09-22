; diff: --cycles 40000
; sysmoves.s - plan M4 tb_ap040_pipe_sysmoves: MOVEC every 68040 selector
; written with all ones and read back through its write mask (TC $0000C000,
; ITT/DTT $FFFFE364 -- written without E, the reference bench cannot run translated, URP/SRP $FFFFFE00, CACR's non-enable bits, SFC/DFC 3 bits),
; USP/ISP/MSP through MOVEC and MOVE USP, an unknown selector (vector 4 in
; supervisor mode), and in user mode: MOVEC, MOVE USP, MOVE from SR,
; MOVE to SR -> vector 8, MOVE from/to CCR allowed.
; expect-inimage
; expect-range: 7000 7100
v_adr	equ	unexp
v_ill	equ	trap_h
v_prv	equ	trap_h
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

rdall	macro
	movec	sfc,d1
	move.l	d1,(a6)+
	movec	dfc,d1
	move.l	d1,(a6)+
	movec	cacr,d1
	move.l	d1,(a6)+
	movec	tc,d1
	move.l	d1,(a6)+
	movec	itt0,d1
	move.l	d1,(a6)+
	movec	itt1,d1
	move.l	d1,(a6)+
	movec	dtt0,d1
	move.l	d1,(a6)+
	movec	dtt1,d1
	move.l	d1,(a6)+
	movec	mmusr,d1
	move.l	d1,(a6)+
	movec	urp,d1
	move.l	d1,(a6)+
	movec	srp,d1
	move.l	d1,(a6)+
	endm

	org	$400
start:
	movea.l	#$7000,a6
	moveq	#-1,d0
	movec	d0,sfc
	movec	d0,dfc
	move.l	#$7FFF7FFF,d7		; CACR: every bit but the two enables (the
	movec	d7,cacr			; reference bench cannot run with caches on)
	move.l	#$FFFF7FFF,d7		; TC: all but E (the MMU stays off): reads $4000
	movec	d7,tc
	movec	d7,itt0			; the TTRs likewise without E (bit 15)
	movec	d7,itt1
	movec	d7,dtt0
	movec	d7,dtt1
	movec	d0,mmusr
	movec	d0,urp
	movec	d0,srp
	rdall
	moveq	#0,d0
	movec	d0,tc
	; ---- stack pointers
	movea.l	#$5000,a0
	move.l	a0,usp
	move	usp,a1
	move.l	a1,(a6)+
	movec	usp,d2
	move.l	d2,(a6)+
	movea.l	#$6000,a2
	movec	a2,msp
	movec	msp,d3
	move.l	d3,(a6)+
	movec	isp,d4
	move.l	d4,(a6)+		; = the current SP (M = 0)
	; ---- an unknown selector in supervisor mode: vector 4
	dc.w	$4E7A,$1008		; movec $008,d1
	; ---- user mode
	move.w	#$0000,sr
	move.w	ccr,d5			; allowed
	move.w	#$1F,ccr		; allowed
	move.w	ccr,d6
	dc.w	$4E7A,$1801		; movec vbr,d1: vector 8
	dc.w	$4E7A,$1008		; unknown selector in user mode: vector 8 too
	move	usp,a3			; vector 8
	move.w	sr,d7			; vector 8
	move.w	#$2700,sr		; vector 8 (the handler returns in supervisor mode after this one)
	move.l	d5,(a6)+
	move.l	d6,(a6)+
	move.l	a3,(a6)+
halt:
	bra.s	halt
; logs the vector offset and stacked PC; skips the faulting instruction
; (all 2 or 4 bytes: the opcode says which); the last one returns in S mode
trap_h:
	move.w	6(sp),(a6)+
	move.l	2(sp),(a6)+
	movem.l	d0/a0,-(sp)
	movea.l	10(sp),a0		; the stacked PC
	move.w	(a0),d0
	andi.w	#$FFFE,d0
	cmpi.w	#$4E7A,d0		; MOVEC: 4 bytes
	bne.s	.two
	addq.l	#2,10(sp)
.two:	addq.l	#2,10(sp)
	cmpi.w	#$46FC,(a0)		; MOVE #,SR (4 bytes): back to supervisor
	bne.s	.out
	addq.l	#2,10(sp)
	ori.w	#$2000,8(sp)
.out:	movem.l	(sp)+,d0/a0
	rte
unexp:
	bra.s	unexp
