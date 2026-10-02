; ldx.s - findings/loadstore/plan.md step 1 (LDX): a load dispatched to EX
; in its lookup clock, before its answer.  Every eligible form, each with
; the use right behind it.  In the bus legs the core has no fast read path
; (rd_fast tied low), so every one of these loads takes LDX's SLOW path:
; dispatched with a provisional operand, held in EX (ld_wait), the port's
; answer written into the micro-op.  The compat bench (cache, fast path)
; runs Dhrystone and the t_*.s programs for the fast path.  With LDX = 0
; the program is an ordinary load/use test and must give the same results.
;
; What each case would catch:
;   1  load, use in the next instruction (an operand left provisional)
;   2  ADD from memory into a register (the source load into x.a)
;   3  word load into Dn, MOVEA.W sign extension
;   4  byte load, TST.B from memory then BEQ on its flags
;   5  (d8,An,Xn) and 6 abs.l sources
;   7  ADDQ to memory: a read-modify-write, the destination load into x.b,
;      and EX's micro-op holding its own store (must not count as older)
;   8  MOVE mem,mem: load and store in one micro-op (the case that
;      deadlocked: the read waited for its own instruction's store)
;   9  MULU.W from memory
;  10  CMPM: the second of two loads
;  11  three loads back to back, the last added from memory
;  12  a store then a load of the same address (forwarding)
;  13  a misaligned longword load
;  14  UNLK (the load from (An) into An and SP)
;
; diff: --cycles 60000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	lea	$6000,a0
	lea	$7000,a5		; results
	moveq	#0,d1
	moveq	#0,d3
	moveq	#0,d4
	moveq	#0,d6
;------------------------------------- 1
	move.l	(a0),d0			; $12345678
	add.l	d0,d1
	move.l	d1,(a5)+		; 7000
;------------------------------------- 2
	move.l	4(a0),d2		; 5
	add.l	(a0),d2			; $1234567D
	move.l	d2,(a5)+		; 7004
;------------------------------------- 3
	move.w	8(a0),d3		; $8001
	movea.w	8(a0),a1		; $FFFF8001
	move.l	d3,(a5)+		; 7008
	move.l	a1,(a5)+		; 700C
;------------------------------------- 4
	move.b	12(a0),d4		; $80
	tst.b	13(a0)			; $01: not zero
	beq	fail
	move.l	d4,(a5)+		; 7010
;------------------------------------- 5, 6
	moveq	#2,d5
	move.b	12(a0,d5.w),d6		; $600E: $02
	move.l	d6,(a5)+		; 7014
	move.l	($6004).l,d7		; 5
	move.l	d7,(a5)+		; 7018
;------------------------------------- 7
	addq.l	#1,16(a0)		; $10000001
	move.l	16(a0),d0
	move.l	d0,(a5)+		; 701C
;------------------------------------- 8
	move.l	20(a0),24(a0)		; $55AA55AA -> $6018
	move.l	24(a0),d0
	move.l	d0,(a5)+		; 7020
;------------------------------------- 9
	mulu.w	30(a0),d7		; 5 * 3
	move.l	d7,(a5)+		; 7024
;------------------------------------- 10
	lea	32(a0),a2
	lea	36(a0),a3
	cmpm.l	(a2)+,(a3)+		; equal
	bne	fail
	move.l	a2,(a5)+		; 7028: $6024
	move.l	a3,(a5)+		; 702C: $6028
;------------------------------------- 11
	move.l	(a0),d0
	move.l	4(a0),d0
	add.l	(a0),d0			; 5 + $12345678
	move.l	d0,(a5)+		; 7030
	tst.l	4(a0)
	beq	fail
	cmp.l	(a0),d1			; d1 = $12345678
	bne	fail
;------------------------------------- 12
	move.l	#$CAFEBABE,40(a0)
	move.l	40(a0),d4
	move.l	d4,(a5)+		; 7034
;------------------------------------- 13
	move.l	$42(a0),d5		; $6042: $CCDD1122
	move.l	d5,(a5)+		; 7038
;------------------------------------- 14
	movea.l	sp,a4
	lea	$6050,a6
	unlk	a6			; a6 = ($6050), sp = $6054
	move.l	a6,(a5)+		; 703C: $13572468
	move.l	sp,(a5)+		; 7040: $6054
	movea.l	a4,sp
	move.l	#1,(a5)+		; 7044: reached the end
	bra.s	halt
fail:
	move.l	#$BAD,(a5)+
halt:
	bra.s	halt

unexp:
	bra.s	unexp

	org	$6000
	dc.l	$12345678		; 6000
	dc.l	$00000005		; 6004
	dc.w	$8001,$7FFF		; 6008
	dc.b	$80,$01,$02,$03		; 600C
	dc.l	$10000000		; 6010
	dc.l	$55AA55AA		; 6014
	dc.l	0			; 6018
	dc.l	$00000003		; 601C (the word at $601E is 3)
	dc.l	$00000001,$00000001	; 6020, 6024
	dc.l	0,0			; 6028, 602C
	dc.l	0,0			; 6030, 6034
	dc.l	0,0			; 6038, 603C
	dc.l	$AABBCCDD,$11223344	; 6040
	dc.l	0,0			; 6048, 604C
	dc.l	$13572468		; 6050
