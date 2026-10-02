; t_cbtab_pipe.s - findings/copyback: translation tables in a COPYBACK page.
; M68040UM 3.2.5: "The cache treats table search accesses that are not
; read-modify-write accesses as cachable/write-through but do not allocate
; in the cache for misses.  Read-modify-write table search accesses
; (required to update some descriptor U-bit and M-bit combinations) are
; treated as noncachable and force a matching cache line to be pushed and
; invalidated."  So a descriptor the program stored into a copyback page,
; still dirty in the data cache, is what the next table search finds.
; (MuSetCacheMode over a whole fast RAM board can leave MMULib's own tables
; in a copyback page.)  Translation on, 4K identity pages; page 5 holds the
; tables and is copyback.  Memory behind the caches is read through the
; bench's peek registers ($F190 address, $F192 the longword).  Runs under
; tb_ap040_pipe_compat.v, with and without COPYBACK (write-through: every
; descriptor store reaches memory, and every case passes trivially).
; Protocol: $F100 = failing check, $F102 = $600D.
;
;   1  an instruction-side walk: the descriptor of page $A000, rewritten
;      to physical $B000 and dirty in the cache, then PFLUSHA; the call
;      to $A000 must run $B000's routine (D0 = 2, not 1)
;   2  a data-side walk: the same for page $C000 -> physical $D000
;   3  a walk that must SET the U bit of a dirty descriptor (page $E000 ->
;      physical $D000, U clear): the read must find the new descriptor,
;      and after CPUSHA memory must hold it with U set (the walker's
;      update not lost under the line's later push)
;   4  a CPUSHA on the last word of page 8 while page 9's descriptor is
;      dirty: the fetch past the CPUSHA walks for page 9 during the sweep,
;      which stalls on a dirty row while the walk is running, and the walk
;      waits for the push of its own descriptor's set -- the cache must
;      push that set from the stalled sweep (else both wait for ever).
;      Page 9 was mapped to physical $3000 (D0 = -1); now to $9000 (D0 = 4)
;   5  a walk does not push a dirty NEIGHBOUR: $5030 dirty in set 3, a walk
;      reads page 13's descriptor ($5434, set 3); memory at $5030 must
;      still be old under copyback ($F196 = 1), new under write-through

FAILREG	equ	$F100
DONEREG	equ	$F102
PEEKA	equ	$F190
PEEKD	equ	$F192
CBMODE	equ	$F196
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000
CM_WT	equ	$00
CM_CB	equ	$20
CM_CI	equ	$40

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	bc
	; tables (written before translation: write-through, in memory)
	lea	ROOT,a0
	move.l	#PTR|$B,(a0)		; resident, U set
	lea	PTR,a0
	move.l	#PAGE|$B,(a0)
	lea	PAGE,a0
	lea	cmtab(pc),a1
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.b	(a1)+,d2
	or.l	#$19,d2			; resident, U and M set
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$3000|CM_WT|$19,PAGE+4*9	; page 9 -> physical $3000 at first
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	pflusha
	move.l	#$8000,d0
	movec	d0,tc

; 1: an instruction-side walk finds the dirty descriptor
	jsr	$A000
	cmp.l	#1,d0
	beq.s	.c1a
	failt	10
.c1a:	move.l	PAGE+4*10,d0		; the descriptor's line is resident
	move.l	#$B000|CM_WT|$19,PAGE+4*10	; a hit: dirty under copyback
	pflusha
	jsr	$A000
	cmp.l	#2,d0
	beq.s	.c2
	failt	1

; 2: a data-side walk finds the dirty descriptor
.c2:	move.l	$C000,d0
	cmp.l	#$C0C0C0C0,d0
	beq.s	.c2a
	failt	20
.c2a:	move.l	PAGE+4*12,d0
	move.l	#$D000|CM_WT|$19,PAGE+4*12
	pflusha
	move.l	$C000,d0
	cmp.l	#$D0D0D0D0,d0
	beq.s	.c3
	failt	2

; 3: the U-bit update of a dirty descriptor
.c3:	move.l	$E000,d0
	cmp.l	#$E0E0E0E0,d0
	beq.s	.c3a
	failt	30
.c3a:	move.l	PAGE+4*14,d0
	move.l	#$D000|CM_WT|$11,PAGE+4*14	; resident, M set, U clear
	pflusha
	move.l	$E000,d0
	cmp.l	#$D0D0D0D0,d0
	beq.s	.c3b
	failt	3
.c3b:	move.l	PAGE+4*14,d0		; the program sees U set
	cmp.l	#$D000|CM_WT|$19,d0
	beq.s	.c3c
	failt	31
.c3c:	cpusha	dc
	move.w	#PAGE+4*14,PEEKA	; and so does memory, after the push
	move.l	PEEKD,d1
	cmp.l	#$D000|CM_WT|$19,d1
	beq.s	.c3d
	failt	32
.c3d:
; 4: the walk past a CPUSHA, over a dirty descriptor
	move.l	PAGE+4*9,d0
	move.l	#$9000|CM_WT|$19,PAGE+4*9	; dirty
	pflusha
	moveq	#0,d0
	jsr	$8FFE				; CPUSHA DC, then page 9
	cmp.l	#4,d0
	beq.s	.c4
	failt	4
.c4:
; 5: the walk leaves a dirty neighbour in its set alone
	move.l	$5030,d0			; resident
	move.l	#$55555555,$5030		; dirty (copyback)
	pflusha
	move.l	$D000,d0			; walks: $5434, set 3
	cmp.l	#$D0D0D0D0,d0
	beq.s	.c5a
	failt	50
.c5a:	move.w	#$5030,PEEKA
	move.l	PEEKD,d1
	tst.w	CBMODE
	beq.s	.c5wt
	tst.l	d1				; copyback: memory still old
	beq.s	.c5
	failt	5
.c5wt:	cmp.l	#$55555555,d1			; write-through: memory new
	beq.s	.c5
	failt	51
.c5:	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; page 5 (the tables) copyback; page 15 the bench registers, inhibited
cmtab:	dc.b	CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_CB,CM_WT,CM_WT
	dc.b	CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_WT,CM_CI

	org	$3000
	moveq	#-1,d0
	rts
	org	$8FFE
	cpusha	dc
	org	$9000
	moveq	#4,d0
	rts
	org	$A000
	moveq	#1,d0
	rts
	org	$B000
	moveq	#2,d0
	rts
	org	$C000
	dc.l	$C0C0C0C0
	org	$D000
	dc.l	$D0D0D0D0
	org	$E000
	dc.l	$E0E0E0E0
