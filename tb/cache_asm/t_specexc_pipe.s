; t_specexc_pipe.s - no data read for the instruction after one that takes
; an exception.  A 68040 issues an operand read only for an instruction it
; executes; the instruction after a TRAP, ILLEGAL, A-line, F-line, a DIVU
; by zero, a failing CHK, TRAPV/TRAPcc with the condition true or a
; privilege violation does not run before the handler (and here the handler
; resumes elsewhere, so it never runs).  An Amiga has read-sensitive
; registers: a read of the write-only SERPER ($DFF032) loads it with bus
; garbage -- the AP040 images' serial port at ~112 baud
; (findings/serial/README.md).  Runs under tb_ap040_pipe_compat.v, whose
; $F180 counts every read of it the core completes (the word at $F182).
; Protocol: $F100 = failing check, $F102 = $600D / $BAD0.
;
;   1 TRAP #0   2 ILLEGAL   3 A-line   4 F-line   5 DIVU #0   6 CHK
;   7 TRAPV     8 TRAPT     9 privilege violation (MOVE to SR in user mode)
; each four times, the second pass onwards with the instruction path hot;
; fail = case number, 10+case when the handler did not run.

FAILREG	equ	$F100
DONEREG	equ	$F102
CNT	equ	$F182

	org	0
	dc.l	$7000
	dc.l	start
	dc.l	unexp,unexp		; 2 access, 3 address
	rept	6
	dc.l	exc			; 4 illegal .. 9 trace
	endr
	dc.l	exc,exc			; 10 A-line, 11 F-line
	rept	20
	dc.l	unexp			; 12-31
	endr
	dc.l	exc			; 32 TRAP #0
	rept	223
	dc.l	unexp
	endr

after	macro				; \1 = case; \2 = resume label
	move.w	(a0),d0			; must never run, nor be read
	move.w	(a0),d0
\2:	tst.w	d4
	bne.s	.h\@
	move.w	#10+\1,d7
	bra	fail_all
.h\@:	move.w	CNT,d0
	beq.s	.ok\@
	move.w	#\1,d7
	bra	fail_all
.ok\@:
	endm

	org	$400
start:	move.l	#$00008000,d0		; IE only: $F180/$F182 are read from memory
	movec	d0,cacr
	cpusha	bc
	lea	$F180,a0
	moveq	#3,d6
.pass:
	clr.w	CNT
	moveq	#0,d4
	lea	.r1,a2
	trap	#0
	after	1,.r1
	clr.w	CNT
	moveq	#0,d4
	lea	.r2,a2
	illegal
	after	2,.r2
	clr.w	CNT
	moveq	#0,d4
	lea	.r3,a2
	dc.w	$A123
	after	3,.r3
	clr.w	CNT
	moveq	#0,d4
	lea	.r4,a2
	dc.w	$FE00			; F-line, coprocessor id 7
	after	4,.r4
	clr.w	CNT
	moveq	#0,d4
	lea	.r5,a2
	moveq	#0,d1
	moveq	#9,d2
	divu.w	d1,d2
	after	5,.r5
	clr.w	CNT
	moveq	#0,d4
	lea	.r6,a2
	moveq	#5,d1
	moveq	#9,d2
	chk.w	d1,d2
	after	6,.r6
	clr.w	CNT
	moveq	#0,d4
	lea	.r7,a2
	move.w	#$2702,sr		; V set
	trapv
	after	7,.r7
	clr.w	CNT
	moveq	#0,d4
	lea	.r8,a2
	trapt
	after	8,.r8
	clr.w	CNT
	moveq	#0,d4
	lea	.r9,a2
	lea	$6800,a1
	move.l	a1,usp
	move.w	#$0700,sr		; user mode
	move.w	#$2700,sr		; privilege violation
	after	9,.r9
	dbra	d6,.pass

	move.w	#$600d,DONEREG
.h:	bra.s	.h

; resume at a2 in supervisor mode, interrupts masked
exc:	moveq	#1,d4
	move.w	#$2700,(sp)
	move.l	a2,2(sp)
	rte

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f
unexp:	move.w	#99,d7
	bra.s	fail_all
