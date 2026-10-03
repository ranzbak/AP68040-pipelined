; Pipelined AP68040, M9.I: a pending interrupt is taken "within one
; instruction boundary" (M68040UM 7.5.1, p. 7-31) -- also under a dense run
; of register operations, posted stores and misaligned reads, where EX, WB
; or the store FIFO is busy at every boundary and every instruction's operand
; read goes out the clock before it starts.  Before the fix, EA-fetch's
; irq_take only ARMED in a clock with no read pending and none going out,
; and only FIRED at a boundary with nothing older in flight -- and it let the
; instruction at the boundary go when it could not fire.  Such a run starved
; the request for its whole length (fuzz seeds 5018/5081, 16+ starts).
; Runs under tb_ap040_pipe_compat.v (the bench's own IPEND checker, tb_must,
; fails at 16 instruction starts; this program checks the architectural
; symptom: the handler's stacked PC lies INSIDE the run that was interrupted).
; Protocol: $F100 word = failing check, $F102 = $600D / $BAD0.
;
;   1  a level-2 request raised d5 clocks (swept 1..63) into a run of
;      64 x (addq / posted store / misaligned read / addq) with the caches on:
;      the handler ran at all
;   2  ... and its stacked PC is inside the run (not after its end)
;   3  the same against a run of 256 register-only instructions
;   4  ... stacked PC inside the run
;   6-7 the same against a run of 256 x (addq / posted store / posted store /
;      addq): EX, WB or the store FIFO is busy at every boundary
;   5  every request was taken exactly once (189 interrupts)

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
IPLDLY		equ	$F148
irq_pc		equ	$3600
cnt_irq		equ	$3604

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	24
	dc.l	unexp		; 2-25
	endr
	dc.l	h_l2		; 26: level 2 autovector
	rept	229
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	move.l	#$80008000,d0		; both caches on (the instruction read
	movec	d0,cacr			; path keeps the pipeline full)
	cpusha	bc
	clr.l	(cnt_irq).l
	moveq	#1,d5

;------------------------------------------------------ run A: stores and misaligned reads
runa_loop:
	clr.l	(irq_pc).l
	lea	$2000,a0
	lea	$2801,a1
	moveq	#0,d0
	move.w	d5,(IPLDLY).l		; level 2, d5 clocks after this store lands
	move.w	#$2000,sr
runa:
	rept	64
	addq.l	#1,d0
	move.l	d0,(a0)+
	move.l	(a1),d1
	addq.l	#1,d0
	endr
runa_end:
	move.w	#$2700,sr
	move.l	(irq_pc).l,d1
	bne.s	runa_taken
	failt	1
runa_taken:
	cmp.l	#runa_end,d1
	blo.s	runa_ok
	failt	2
runa_ok:
	addq.w	#1,d5
	cmp.w	#64,d5
	bne	runa_loop

;------------------------------------------------------ run B: register operations only
	moveq	#1,d5
runb_loop:
	clr.l	(irq_pc).l
	moveq	#0,d0
	move.w	d5,(IPLDLY).l
	move.w	#$2000,sr
runb:
	rept	128
	addq.l	#1,d0
	add.l	d0,d1
	endr
runb_end:
	move.w	#$2700,sr
	move.l	(irq_pc).l,d1
	bne.s	runb_taken
	failt	3
runb_taken:
	cmp.l	#runb_end,d1
	blo.s	runb_ok
	failt	4
runb_ok:
	addq.w	#1,d5
	cmp.w	#64,d5
	bne	runb_loop

;------------------------------------------------------ run C: posted stores only
; (EX, WB or the store FIFO is busy at every boundary: the old irq_go never
; fired inside this run, and the old arm let every instruction through)
	moveq	#1,d5
runc_loop:
	clr.l	(irq_pc).l
	lea	$2000,a0
	moveq	#0,d0
	move.w	d5,(IPLDLY).l
	move.w	#$2000,sr
runc:
	rept	64
	addq.l	#1,d0
	move.l	d0,(a0)+
	move.w	d0,(a0)+
	addq.l	#1,d0
	endr
runc_end:
	move.w	#$2700,sr
	move.l	(irq_pc).l,d1
	bne.s	runc_taken
	failt	6
runc_taken:
	cmp.l	#runc_end,d1
	blo.s	runc_ok
	failt	7
runc_ok:
	addq.w	#1,d5
	cmp.w	#64,d5
	bne	runc_loop

	move.l	(cnt_irq).l,d0
	cmp.l	#189,d0
	beq.s	done
	failt	5
done:
	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
fh:	bra.s	fh

;------------------------------------------------------ handlers
h_l2:
	move.w	#0,(IPLREG).l		; acknowledge the device
	move.l	2(sp),(irq_pc).l	; the instruction it was taken in front of
	addq.l	#1,(cnt_irq).l
	rte

unexp:
	move.w	#99,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
uh:	bra.s	uh
