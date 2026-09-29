; t_sbmmu_pipe.s - findings/storebuf/plan.md stage 4: stores posted with
; translation on (SB_MMU).  A synchronous store the MMU forwards without a
; fault or a walk, to a writable, cacheable page in RAM, makes its page an
; entry of the core's postable-page table; later stores to it are posted.
; Every case must still fault precisely where a 68040 faults.  Runs under
; tb_ap040_pipe_compat.v.  Protocol: $F100 = failing check, $F102 = $600D.
;
;   1  256 longword stores to page 2 (posted after the first), read back
;   5  page 9's descriptor starts with M clear: its first store walks and
;      sets M, later ones post; the descriptor has M set afterwards
;   6  logical page B mapped to physical $4000: the stores land there
;   2  page 3 stored to (it becomes postable), then made write-protected and
;      PFLUSHA: the next store takes a precise access error (FA $3000) and
;      does not change memory -- a stale table entry would post it and the
;      fault would come late (fatal)
;   3  MOVEC TC off and on between stores: correct data
;   4  page 8 is supervisor-only: supervisor stores make it postable for FC
;      5; a USER store to it must fault (FA $8004), not be posted
;   7  a longword across the page 1/page 2 boundary ($1FFE): correct
;   8  the results are checked with translation off

FAILREG	equ	$F100
DONEREG	equ	$F102
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000
NAERR	equ	$6000		; access errors taken
FA0	equ	$6004		; their fault addresses
FA1	equ	$6008

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$7000
	dc.l	start
	dc.l	h_aerr		; 2 access error
	rept	29
	dc.l	unexp
	endr
	dc.l	h_trap		; 32 TRAP #0: back to supervisor mode
	rept	223
	dc.l	unexp
	endr

	org	$400
start:	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	bc
	clr.l	NAERR
	; tables: 16 identity 4K pages, page 8 supervisor-only, page B -> $4000
	lea	ROOT,a0
	move.l	#PTR|3,(a0)
	lea	PTR,a0
	move.l	#PAGE|3,(a0)
	lea	PAGE,a0
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.l	#1,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$8000|$80|1,PAGE+8*4	; S
	move.l	#$4000|1,PAGE+11*4	; page B -> physical $4000
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	pflusha
	move.l	#$8000,d0
	movec	d0,tc

; 1: posting under translation
	lea	$2000,a0
	move.l	#$01010101,d0
	move.w	#255,d1
.s1:	move.l	d0,(a0)+
	add.l	#$01010101,d0
	dbra	d1,.s1
	lea	$2000,a0
	move.l	#$01010101,d0
	move.w	#255,d1
.r1:	cmp.l	(a0)+,d0
	beq.s	.k1
	failt	1
.k1:	add.l	#$01010101,d0
	dbra	d1,.r1

; 5: a page with M clear
	move.l	#$99999999,$9000
	move.l	#$9999aaaa,$9004
	move.l	#$9999bbbb,$9008

; 6: logical page B -> physical $4000
	move.l	#$bbbb0001,$b100
	move.l	#$bbbb0002,$b104

; 2: write-protect after the page became postable
	move.l	#$30303030,$3000
	move.l	#$31313131,$3004
	move.l	PAGE+3*4,d0
	or.l	#4,d0			; W
	move.l	d0,PAGE+3*4
	pflusha
	move.l	#$deaddead,$3000	; must fault precisely
	cmp.l	#1,NAERR
	beq.s	.k2
	failt	2

; 3: TC off and on between stores
.k2:	move.l	#$24242424,$2400
	moveq	#0,d0
	movec	d0,tc
	move.l	#$24242425,$2404
	move.l	#$8000,d0
	movec	d0,tc
	move.l	#$24242426,$2408

; 4: a supervisor-only page, then a user store to it
	move.l	#$80808080,$8000	; supervisor: allowed, the page becomes postable
	move.l	#$80808081,$8008
	lea	$6800,a0
	move.l	a0,usp
	andi.w	#$dfff,sr		; user mode
	move.l	#$deaddead,$8004	; must fault (S)
	trap	#0			; back to supervisor mode
	cmp.l	#2,NAERR
	beq.s	.k4
	failt	4

; 7: a longword across pages 1 and 2
.k4:	move.l	#$11223344,$1ffe

; 8: translation off, check
	moveq	#0,d0
	movec	d0,tc
	pflusha
	cpusha	dc
	cmp.l	#$30303030,$3000	; the protected store did not land
	beq.s	.c8a
	failt	8
.c8a:	cmp.l	#$3000,FA0
	beq.s	.c8b
	failt	18
.c8b:	cmp.l	#$8004,FA1
	beq.s	.c8c
	failt	28
.c8c:	move.l	PAGE+9*4,d0
	and.l	#$10,d0			; M
	bne.s	.c8d
	failt	38
.c8d:	cmp.l	#$9999bbbb,$9008
	beq.s	.c8e
	failt	48
.c8e:	cmp.l	#$bbbb0002,$4104	; the remapped page's physical home
	beq.s	.c8f
	failt	58
.c8f:	cmp.l	#$24242426,$2408
	beq.s	.c8g
	failt	68
.c8g:	cmp.l	#$11223344,$1ffe
	beq.s	.c8h
	failt	78
.c8h:	cmp.l	#$80808081,$8008
	beq.s	.c8i
	failt	88
.c8i:	cmp.l	#0,$8004		; the user store did not land
	beq.s	.c8j
	failt	98
.c8j:
	move.w	#$600d,DONEREG
.h:	bra.s	.h

; an access error: count it, keep its fault address, return past the store
; (a write fault on the instruction's last micro-op: WB1 holds the write and
; the stacked PC is the next instruction; not completing it drops the store)
h_aerr:	cmpi.w	#$7008,6(sp)
	bne.s	.bad
	move.l	d0,-(sp)
	move.l	NAERR,d0
	lsl.l	#2,d0
	move.l	$14+4(sp),(FA0,d0.l)
	addq.l	#1,NAERR
	move.l	(sp)+,d0
	rte
.bad:	move.w	#97,d7
	bra.s	fail_all
h_trap:	ori.w	#$2000,(sp)		; return in supervisor mode
	rte

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all
