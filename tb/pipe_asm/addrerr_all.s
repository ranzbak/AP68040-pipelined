; addrerr_all.s - address error (vector 3, format $2) on every odd
; control-flow target (M68040UM 8.2.2 p. 8-8), with the stacked PC the
; reference core stacks (ap040_core.v finish_bcc, S_BCC_EXT, S_DBCC1,
; S_JMP1, S_JSR1, S_RET2, S_RTE_FIN2 -- validated against the cputest AE
; group):
;   Bcc taken / not taken, BSR (no push), DBcc (before the condition):
;       PC = the branch
;   JMP (An): PC = JMP+2; JMP (d8,An,Xn): PC = JMP+6
;   JSR (An): PC = the odd target, no push
;   RTS: PC = the RTS, SP not popped
;   RTE: SR and SP restored first, PC = the RTE
; The handler logs A7 and the 12-byte frame at (A5)+, pops the frame and
; continues at A6.  Plan M1 tb_ap040_pipe_addrerr_all.
; expect-mem: m32 1400 m32 1404 m32 1408 m32 140c m32 1410 m32 1414 m32 1418 m32 141c m32 1420 m32 1424 m32 1428 m32 142c m32 1430 m32 1434 m32 1438 m32 143c m32 1440 m32 1444 m32 1448 m32 144c m32 1450 m32 1454 m32 1458 m32 145c m32 1460 m32 1464 m32 1468 m32 146c m32 1470 m32 1474 m32 1478 m32 147c m32 1480 m32 1484 m32 1488 m32 148c
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

	org	$400
start:
	movea.l	#log,a5
	moveq	#0,d0		; Z = 1
; 1: BRA.S to odd, taken
	movea.l	#t2,a6
t1:	dc.w	$6001		; BRA.S *+3
; 2: BNE.S to odd, not taken
t2:	movea.l	#t3,a6
	moveq	#0,d0
	dc.w	$6601		; BNE.S *+3 (Z=1: not taken, still faults)
; 3: BSR.S to odd: no push
t3:	movea.l	#t4,a6
	dc.w	$6101		; BSR.S *+3
; 4: DBT D1,odd: faults before the condition
t4:	movea.l	#t5,a6
	dc.w	$50C9,$0001	; DBT D1,*+3
; 5: JMP (A0) odd
t5:	movea.l	#t6,a6
	movea.l	#$00000801,a0
	jmp	(a0)
; 6: JMP (d8,A0,D0.W) odd
t6:	movea.l	#t7,a6
	moveq	#0,d0
	jmp	0(a0,d0.w)
; 7: JSR (A0) odd: no push, PC = target
t7:	movea.l	#t8,a6
	jsr	(a0)
; 8: RTS to odd: SP not popped
t8:	movea.l	#t9,a6
	move.l	#$00000803,-(a7)
	rts
; 9: RTE to odd PC
t9:	movea.l	#t10,a6
	move.l	(a7)+,d7	; drop the RTS case's pushed longword
	move.w	#0,-(a7)	; format $0 / vector 0
	move.l	#$00000805,-(a7)
	move.w	#$2704,-(a7)	; SR with Z set
	rte
t10:
halt:
	bra.s	halt

v_adr:
	move.l	a7,(a5)+
	move.l	(a7)+,(a5)+	; SR, PC hi
	move.l	(a7)+,(a5)+	; PC lo, format/vector
	move.l	(a7)+,(a5)+	; address
	jmp	(a6)

unexp:
	moveq	#-1,d6
	bra.s	unexp

	org	$1400
log:	dcb.b	160,$00
