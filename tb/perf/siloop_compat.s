; siloop_compat.s -- SysInfo 4.4's SPEED loop on tb_ap040_pipe_compat.v
; (perf measurement, PLAN M11, 2026-09-24).  The loop block itself is NOT in
; this file: findings/ap040-pipelined/tests/perf/mk_siloop.py extracts it
; from the SysInfo executable (hunk 0 $30A4-$335B, three size-preserving
; patches) as siloop_0.bin for base 0, and this program incbins it at $30A4,
; so every byte keeps its SysInfo cache-line alignment.  Its table lands at
; $45C4 and the iteration bound at $480C (a4), where SysInfo keeps them.
;
; Window protocol (tb/perf/tb_perf_compat.v): a nonzero word to $F1F0
; opens the measured window, zero closes it.  One warm-up iteration, then
; NITER measured ones.  Passes with $600D at $F102.
	ifnd	NITER
NITER	equ	4
	endif
	ifnd	CACRV
CACRV	equ	$80008000		; IE + DE, as 68040.library leaves it
	endif

	org	0
	dc.l	$7000			; SSP
	dc.l	start
	rept	254
	dc.l	fail
	endr

	org	$400
start:	move.l	#CACRV,d0
	movec	d0,cacr
	ifd	MMU
	; MMU=1: translation ON through an identity map of the 64 KB (4K pages,
	; write-through cacheable), no transparent translation -- every access
	; goes through the ATC, as with 68040.library/MuForce page tables
	lea	$5000,a0		; root: entry 0 -> pointer table
	move.l	#$5200|3,(a0)
	lea	$5200,a0		; pointer: entry 0 -> page table
	move.l	#$5400|3,(a0)
	lea	$5400,a0		; page table: pages 0-15 identity, resident
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.l	#1,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$5000,d0
	movec	d0,srp
	movec	d0,urp
	moveq	#0,d0
	movec	d0,itt0
	movec	d0,itt1
	movec	d0,dtt0
	movec	d0,dtt1
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	endif
	lea	$480c,a4
	moveq	#0,d7
	move.l	#1,(a4)			; warm-up: one iteration
	jsr	$30a4
	move.w	#1,$f1f0		; open the window
	moveq	#0,d7
	move.l	#NITER,(a4)
	jsr	$30a4
	move.w	#0,$f1f0		; close it
	cmp.l	#NITER,d7
	bne.s	fail
	move.w	#$600d,$f102
.h:	bra.s	.h
fail:	move.w	#1,$f100
	move.w	#$bad0,$f102
.f:	bra.s	.f

	org	$30a4
	incbin	"siloop_0.bin"
	org	$45c4
	incbin	"siloop_0.bin.tab"
	org	$480c
	dc.l	0
