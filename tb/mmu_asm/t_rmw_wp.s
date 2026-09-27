; t_rmw_wp.s - audit 2026-09-27, finding 4: the READ of a locked
; read-modify-write (TAS, CAS, CAS2) is checked for write protection
; (M68040UM 3.2.2.3): a protected operand faults on the read -- stacked PC
; = the instruction (a restart), SSW LK and ATC, no pending WB1 -- and a CAS
; or CAS2 whose compare fails, which never writes, still faults.
; Runs under tb_ap040_pipe_compat.v (the wrapper with the lifted MMU).
; Protocol: $F100 word = failing check, $F102 word = $600D / $BAD0.
;
;   1  an ordinary read of the protected page does not fault
;   2  TAS on it: one read fault at the TAS (was: a WRITE fault, pending
;      WB1, PC past the instruction); the handler unprotects, the restart
;      sets bit 7
;   3  CAS.L whose compare fails: one read fault (was: none)
;   4  CAS2.L whose compare fails, first operand protected: one read fault
;      (was: none, the CAS2 completed)
;   5  an ordinary read of the protected page right after a TAS elsewhere
;      does not fault (the lock belongs to the TAS's own read only)

FAILREG		equ	$F100
DONEREG		equ	$F102
cnt_aerr	equ	$3600
last_ssw	equ	$3602
last_fa		equ	$3604
last_pc		equ	$3608
last_wb1s	equ	$360C
fix_addr	equ	$3610
fix_val		equ	$3614

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

protect	macro
	move.l	#$00005007,($4414).l	; page 5 identity, W = 1
	move.l	#$00004414,(fix_addr).l
	move.l	#$00005003,(fix_val).l	; the handler makes it writable
	pflusha
	clr.w	(cnt_aerr).l
	endm

	org	0
	dc.l	$3400
	dc.l	start
	dc.l	h_aerr
	rept	253
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	clr.w	(cnt_aerr).l
	lea	($4400).l,a0		; 64 x 4K identity, resident
	moveq	#0,d0
	moveq	#63,d1
tl:	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#4,d2
	addq.l	#3,d2
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,tl
	move.l	#$00004203,($4000).l
	move.l	#$00004403,($4200).l
	move.l	#$12345678,($5000).l
	move.l	#$00000011,($5010).l
	move.l	#$22222222,($5020).l
	move.l	#$33333333,($6000).l
	moveq	#5,d0
	movec	d0,dfc
	move.l	#$4000,d0
	movec	d0,urp
	movec	d0,srp
	move.l	#$8000,d0		; E, 4K pages
	movec	d0,tc
	pflusha

;------------------------------------- 1: a plain read does not fault
	protect
	move.l	($5000).l,d0
	chkl	d0,$12345678,1
	moveq	#0,d0
	move.w	(cnt_aerr).l,d0
	chkl	d0,0,2

;------------------------------------- 2: TAS faults on its locked read
	protect
	lea	($5010).l,a1
c2:	tas	(a1)
	moveq	#0,d0
	move.w	(cnt_aerr).l,d0
	chkl	d0,1,3			; one fault
	move.l	(last_pc).l,d0
	chkl	d0,c2,4			; at the TAS: a restart, not past it
	move.l	(last_fa).l,d0
	chkl	d0,$00005010,5
	moveq	#0,d0
	move.w	(last_ssw).l,d0
	andi.w	#$0600,d0		; ATC (bit 10) and LK (bit 9)
	chkl	d0,$0600,6
	move.l	(last_wb1s).l,d0
	chkl	d0,0,7			; no pending write: the READ faulted
	move.b	($5010).l,d0
	andi.l	#$FF,d0
	chkl	d0,$80,8		; the restarted TAS set bit 7 ($5010 held $00)

;------------------------------------- 3: CAS whose compare fails
	protect
	lea	($5020).l,a2
	move.l	#$0BADBAD0,d1		; compare value: not equal
	move.l	#$44444444,d2
	cas.l	d1,d2,(a2)
	moveq	#0,d0
	move.w	(cnt_aerr).l,d0
	chkl	d0,1,9			; faulted although it never writes
	chkl	d1,$22222222,10		; Dc loaded with the operand
	move.l	($5020).l,d0
	chkl	d0,$22222222,11		; unchanged

;------------------------------------- 4: CAS2 whose compare fails
	protect
	lea	($5000).l,a3		; first operand: protected page 5
	lea	($6000).l,a4		; second: page 6, writable
	move.l	#$0BADBAD0,d3		; Dc1: not equal
	move.l	#$33333333,d4		; Dc2
	move.l	#$55555555,d5
	move.l	#$66666666,d6
	cas2.l	d3:d4,d5:d6,(a3):(a4)
	moveq	#0,d0
	move.w	(cnt_aerr).l,d0
	chkl	d0,1,12
	chkl	d3,$12345678,13
	move.l	($6000).l,d0
	chkl	d0,$33333333,14		; nothing written


;------------------------------------- 5: the NEXT instruction's read is not locked
; (final review I1) a TAS on a writable page, then an ordinary read of the
; protected page right behind it: its early read must not inherit the TAS's
; lock bit and take a write-protection fault on a readable page
	protect
	lea	($6000).l,a5		; page 6: writable
	tas	(a5)
	move.l	($5000).l,d0		; page 5: protected, but only READ
	moveq	#0,d1
	move.w	(cnt_aerr).l,d1
	chkl	d1,0,15
	chkl	d0,$12345678,16

	move.w	#$600D,(DONEREG).l
done:	bra.s	done

h_aerr:
	movem.l	d0-d1/a0,-(sp)
	cmpi.w	#$7008,$12(sp)		; format $7, vector 2
	bne	unexp
	move.w	$18(sp),(last_ssw).l	; SSW
	move.l	$20(sp),(last_fa).l	; FA
	move.l	$0E(sp),(last_pc).l	; stacked PC
	moveq	#0,d0
	move.w	$1E(sp),d0		; WB1S
	andi.w	#$0080,d0
	move.l	d0,(last_wb1s).l
	movea.l	(fix_addr).l,a0
	move.l	(fix_val).l,(a0)
	pflusha
	btst	#7,d0			; WB1S valid: the handler does the write
	beq.s	h_nowb
	movea.l	$34(sp),a0
	move.l	$38(sp),(a0)
h_nowb:
	addq.w	#1,(cnt_aerr).l
	movem.l	(sp)+,d0-d1/a0
	rte

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
