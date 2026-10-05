; t_dfpmis_pipe.s - findings/loadstore/plan.md step 3 (AP040_DFP_MIS): a
; misaligned word or longword read inside one 4K page is served by the data
; read path as two consecutive lookups of the D-bank copy (ap040_cache.v
; g_dfp, the wrapper's dfp_mok_q/dfp_m2c_q, the core's d_rd_hold/dfp_m2).
; Runs under tb_ap040_pipe_compat.v (cache_allow_all = 1) with its DMA agent
; ($F1E4 address, $F1E6 data, $F1EA = 1 no snoop, $F1E8 = delay arms it) and
; $F198 = 1 when the build has AP040_DFP_MIS.  Protocol: $F100 = failing
; check, $F102 = $600D / $BAD0.
;
; How a served read is told from one that fell back to the port: the lines
; are cached with pattern P, then memory is changed to pattern Q behind the
; cache's back (DMA, no snoop).  A read the path serves returns P (the
; architected stale-until-invalidate value of a cache the chipset does not
; snoop); one that goes out on the port returns Q (a misaligned read
; bypasses the cache there).  Expected values are assembled at run time
; from byte copies of P and Q, so a torn mix of the two is caught as well.
; Mode "served" expects P with the feature compiled in and Q without it;
; mode "mem" expects Q always.  With AP040_DFP_MIS = 0 every read is "mem"
; and the program is a plain misaligned-read test.
;
;   1x  every misalignment inside one line: longwords at offsets 1, 2, 3,
;       5, 6, 7, 9, 10, 11 and words at 1, 3, 5, 7, 9, 11, 13 (served)
;   2x  across the line end, both lines resident: longwords at 13, 14, 15,
;       the word at 15 (served)
;   3x  the second line not resident (a decoy line in its set): the fast
;       path falls back; the cache (MIS, same switch) serves the resident
;       line's bytes (P) and fills the other (Q) -- a mixed value, what a
;       68040 returns -- and without the feature every byte is Q (mem)
;   4x  the first line not resident: the same the other way round
;   5x  across a 4K page end ($2FFD..$2FFF; the decoy line at $2000 holds
;       what a tag that forgot the carry would find): mem
;   6x  across the 1K bank boundary ($23FD..$23FF -> $2400: the second
;       longword's tag is the first's plus one): served
;   7x  a chipset DMA write with its snoop landing 0..47 clocks into a
;       burst of line-crossing reads, on either line: the values read
;       change at most once, from old to new, never back, never a mix
;   8x  tight loops of stores and misaligned reads of the same longwords:
;       a store to the second longword (posted, in the FIFO or in WB), a
;       misaligned store then aligned and misaligned reads of it
;   9x  the eligible instruction forms with a misaligned operand (ADD, CMP,
;       TST, AND, OR, MOVEA, MOVEM, MOVE mem,mem, ADDQ to memory) give the
;       right values (the LDX exclusion)
;  10x  translation on (4K pages, logical page 2 -> physical $4000): the
;       path serves through the data ATC copy; the page made
;       cache-inhibited (CM = 10): mem; the 1K-bank case with translation
;  12x  (MIS) a misaligned store MERGES into the resident line(s) -- inside a
;       line, across two lines, an odd word -- instead of clearing the rows;
;       memory gets the whole store either way (peeked)
;  13x  (MIS) a misaligned read that misses FILLS its line(s): later aligned
;       reads are served from them (memory changed behind the cache); the
;       second line's fill writes its own set's row (136/137)
;  14x  (MIS, copyback builds) a misaligned store to a copyback page: both
;       pieces hit -> both lines dirty, memory untouched until CPUSHA; the
;       second piece misses -> memory written whole, the hit line merged;
;       the first misses -> the same (140, 149)
;  15x  (MIS) a chipset write with its snoop to the second line of a
;       line-crossing store, swept 0..47 clocks over a burst of such stores
;       (translation on; copyback in copyback builds): cache and memory agree

FAILREG	equ	$F100
DONEREG	equ	$F102
DMA_A	equ	$F1E4
DMA_D	equ	$F1E6
DMA_GO	equ	$F1E8
DMA_NS	equ	$F1EA
FEAT	equ	$F198
CBFEAT	equ	$F196
PEEK_A	equ	$F190
PEEK_D0	equ	$F192
PEEK_D1	equ	$F194
REFR	equ	$6380		; byte copy of R
X	equ	$2100		; lines L0 $2100 (set $10) and L1 $2110 (set $11)
DEC0	equ	$2500		; decoy lines in the same sets (pattern R)
DEC1	equ	$2510
XP	equ	$2FF0		; a 4K page end: $2FF0 (set $3F) and $3000 (set 0)
XD	equ	$2000		; the line a tag without the carry names for $3000
XW	equ	$23F0		; a 1K bank end: $23F0 (set $3F) and $2400 (set 0)
XM	equ	$4100		; physical home of logical X with translation on
XWM	equ	$43F0		; ... and of XW
REFP	equ	$6300		; byte copies of P and Q (32 bytes each)
REFQ	equ	$6340
BUF	equ	$6800		; the snoop sweep's samples
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000
PBASE	equ	$A0		; P(i) = $A0 + i, Q(i) = $40 + i, R(i) = $C0 + i, S(i) = $E0 + i
QBASE	equ	$40
RBASE	equ	$C0
SBASE	equ	$E0

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

; a longword probe: \1 base, \2 offset, \3 mode (0 mem, 1 served), \4 check
; number.  The expected values are assembled from the byte copies first,
; then a short wait lets every store drain (the fast path is refused with a
; store in flight, which is a different rule), then the read.
PL	macro
	lea	REFP+\2,a0
	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	lea	REFQ+\2,a0
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	moveq	#\3,d4
	move.w	#\4,d7
	moveq	#7,d1
.w\@:	dbra	d1,.w\@
	move.l	\1+\2,d0
	bsr	chkl
	endm

; (MIS) a probe across two lines of which ONE is resident: the cache serves
; the resident line's longword and fills the other, so the bytes in the
; resident line read P and the others Q (what a 68040 does).  Without the
; feature every byte is Q (the whole read bypassed).  \4 = 0: the first
; line (X..X+15) is resident, 1: the second.  d2 = the mixed value, d3 = Q.
BX	macro
	lsl.l	#8,d2
	ifne	(((\1)<16)&1)-(\2)
	move.b	REFP+\1,d2
	else
	move.b	REFQ+\1,d2
	endif
	endm
PLX	macro
	moveq	#0,d2
	BX	\2+0,\4
	BX	\2+1,\4
	BX	\2+2,\4
	BX	\2+3,\4
	lea	REFQ+\2,a0
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	moveq	#1,d4
	move.w	#\3,d7
	moveq	#7,d1
.w\@:	dbra	d1,.w\@
	move.l	\1+\2,d0
	bsr	chkl
	endm
PWX	macro
	moveq	#0,d2
	BX	\2+0,\4
	BX	\2+1,\4
	lea	REFQ+\2,a0
	moveq	#0,d3
	move.b	(a0)+,d3
	lsl.w	#8,d3
	move.b	(a0)+,d3
	moveq	#1,d4
	move.w	#\3,d7
	moveq	#0,d0
	moveq	#7,d1
.w\@:	dbra	d1,.w\@
	move.w	\1+\2,d0
	bsr	chkw
	endm

; a word probe, the same
PW	macro
	lea	REFP+\2,a0
	moveq	#0,d2
	move.b	(a0)+,d2
	lsl.w	#8,d2
	move.b	(a0)+,d2
	lea	REFQ+\2,a0
	moveq	#0,d3
	move.b	(a0)+,d3
	lsl.w	#8,d3
	move.b	(a0)+,d3
	moveq	#\3,d4
	move.w	#\4,d7
	moveq	#0,d0
	moveq	#7,d1
.w\@:	dbra	d1,.w\@
	move.w	\1+\2,d0
	bsr	chkw
	endm

	org	0
	dc.l	$7E00
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	bc
	clr.w	DMA_NS
	moveq	#0,d5
	move.w	FEAT,d5			; d5 = 1: the path serves misaligned reads

; the byte copies of P and Q
	lea	REFP,a0
	move.w	#PBASE,d0
	bsr	wrpat
	lea	REFQ,a0
	move.w	#QBASE,d0
	bsr	wrpat
	lea	REFR,a0
	move.w	#RBASE,d0
	bsr	wrpat

; ---- 1x/2x: X cached with P, memory Q
	lea	X,a0
	bsr	cacheP
	lea	X,a0
	bsr	patchQ
	PL	X,1,1,11
	PL	X,2,1,12
	PL	X,3,1,13
	PL	X,5,1,14
	PL	X,6,1,15
	PL	X,7,1,16
	PL	X,9,1,17
	PL	X,10,1,18
	PL	X,11,1,19
	PW	X,1,1,21
	PW	X,3,1,22
	PW	X,5,1,23
	PW	X,7,1,24
	PW	X,9,1,25
	PW	X,11,1,26
	PW	X,13,1,27
	PL	X,13,1,31
	PL	X,14,1,32
	PL	X,15,1,33
	PW	X,15,1,34

; ---- 3x: L1 not resident, a decoy in its set
	cpusha	dc
	lea	X,a0
	move.w	#PBASE,d0
	bsr	wrpat			; memory P (write-through, no allocate)
	lea	DEC1,a0
	move.w	#RBASE,d0
	bsr	wrpat
	move.l	X,d0			; L0 cached (one line only)
	move.l	X+4,d0
	move.l	X+8,d0
	move.l	X+12,d0
	move.l	DEC1,d0			; the decoy in L1's set
	lea	X,a0
	bsr	patchQ
	PLX	X,13,41,0
	PLX	X,14,42,0
	PLX	X,15,43,0
	PWX	X,15,44,0
	PL	X,1,1,45		; (control: the first line is served)
	PL	X,10,1,46

; ---- 4x: L0 not resident, L1 is
	cpusha	dc
	lea	X,a0
	move.w	#PBASE,d0
	bsr	wrpat
	lea	DEC0,a0
	move.w	#RBASE,d0
	bsr	wrpat
	move.l	X+16,d0			; L1 cached
	move.l	X+20,d0
	move.l	X+24,d0
	move.l	X+28,d0
	move.l	DEC0,d0			; the decoy in L0's set
	lea	X,a0
	bsr	patchQ
	PLX	X,13,51,1
	PLX	X,14,52,1
	PLX	X,15,53,1
	PWX	X,15,54,1
	PL	X,17,1,55		; (control: the second line is served)
	PW	X,19,1,56

; ---- 5x: a 4K page end
	cpusha	dc
	lea	XP,a0
	bsr	cacheP
	lea	XD,a0
	move.w	#SBASE,d0
	bsr	wrpat
	move.l	XD,d0			; the decoy line at $2000 (set 0, tag $2000)
	move.l	XD+4,d0
	lea	XP,a0
	bsr	patchQ
	PL	XP,13,0,61
	PL	XP,14,0,62
	PL	XP,15,0,63
	PW	XP,15,0,64
	PL	XP,1,1,65		; (control: inside either line, served)
	PL	XP,17,1,66
	PW	XP,19,1,67

; ---- 6x: the 1K bank end, translation off
	cpusha	dc
	lea	XW,a0
	bsr	cacheP
	lea	XW,a0
	bsr	patchQ
	PL	XW,13,1,71
	PL	XW,14,1,72
	PL	XW,15,1,73
	PW	XW,15,1,74
	PL	XW,9,1,75
	PL	XW,17,1,76

; ---- 7x: the snoop sweep.  The longword at X+14 spans L0 ($2100) and L1
; ($2110); the DMA word lands in L0 (at X+14) in the first sweep and in L1
; (at X+16) in the second, 0..47 clocks into 24 back-to-back reads.
	cpusha	dc
	lea	swp7,a4
	move.w	#X+14,d6		; the DMA target
	move.l	#$ABCD5566,a3		; the new value of the longword at X+14
	bsr	sweep7
	move.w	#X+16,d6
	move.l	#$3344ABCD,a3
	bsr	sweep7

; ---- 8x: stores and misaligned reads of the same longwords, tight
	cpusha	dc
	lea	X,a0
	bsr	cacheP
	move.l	#$01020304,d6
	move.l	#$F0E1D2C3,a2
	move.w	#99,d4
.l8:	move.l	d6,X			; LW0
	move.l	a2,X+4			; LW1: in WB or the FIFO when the read looks up
	move.l	X+2,d0
	move.l	d6,d2
	swap	d2
	clr.w	d2
	move.l	a2,d3
	swap	d3
	and.l	#$FFFF,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c81
	failt	81
.c81:	move.l	a2,X+4
	moveq	#0,d0
	move.w	X+3,d0			; {LW0[7:0], LW1[31:24]}
	move.l	d6,d2
	lsl.w	#8,d2
	move.l	a2,d3
	rol.l	#8,d3
	move.b	d3,d2
	and.l	#$FFFF,d2
	cmp.l	d2,d0
	beq.s	.c82
	failt	82
.c82:	move.l	d6,X
	move.l	X+1,d0			; {LW0[23:0], LW1[31:24]}
	move.l	d6,d2
	lsl.l	#8,d2
	move.l	a2,d3
	rol.l	#8,d3
	move.b	d3,d2
	cmp.l	d2,d0
	beq.s	.c83
	failt	83
.c83:	move.l	a2,X+4
	move.l	X+3,d0			; {LW0[7:0], LW1[31:8]}
	move.l	d6,d2
	ror.l	#8,d2
	and.l	#$FF000000,d2
	move.l	a2,d3
	lsr.l	#8,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c84
	failt	84
.c84:
	; a misaligned store, then aligned and misaligned reads of it
	move.l	a2,X
	move.l	a2,X+4
	move.l	d6,X+2
	move.l	X,d0			; {a2[31:16], d6[31:16]}
	move.l	a2,d2
	clr.w	d2
	move.l	d6,d3
	swap	d3
	and.l	#$FFFF,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c85
	failt	85
.c85:	move.l	X+4,d0			; {d6[15:0], a2[15:0]}
	move.l	d6,d2
	swap	d2
	clr.w	d2
	move.l	a2,d3
	and.l	#$FFFF,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c86
	failt	86
.c86:	move.l	d6,X+2
	move.l	X+2,d0			; the store itself (forwarded or from memory)
	cmp.l	d6,d0
	beq.s	.c87
	failt	87
.c87:	moveq	#0,d0
	move.w	X+1,d0			; {a2[23:16], d6[31:24]}
	move.l	a2,d2
	lsr.l	#8,d2
	and.l	#$FF00,d2
	move.l	d6,d3
	rol.l	#8,d3
	and.l	#$FF,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c88
	failt	88
.c88:	move.l	X+1,d0			; {a2[23:16], d6[31:8]}
	move.l	a2,d2
	lsl.l	#8,d2
	and.l	#$FF000000,d2
	move.l	d6,d3
	lsr.l	#8,d3
	or.l	d3,d2
	cmp.l	d2,d0
	beq.s	.c89
	failt	89
.c89:	add.l	#$01030507,d6
	add.l	#$0F0E0D0C,a2
	dbra	d4,.l8

; ---- 9x: instruction forms with a misaligned operand (X holds P again)
	lea	X,a0
	bsr	cacheP
	move.l	#$00000001,d0
	add.l	X+2,d0			; $A2A3A4A5 + 1
	cmp.l	#$A2A3A4A6,d0
	beq.s	.c91
	failt	91
.c91:	move.l	#$A2A3A4A5,d0
	cmp.l	X+2,d0
	beq.s	.c92
	failt	92
.c92:	tst.w	X+3			; $A3A4: negative, not zero
	bmi.s	.c93
	failt	93
.c93:	move.l	#$0F0F0F0F,d0
	and.l	X+1,d0			; $A1A2A3A4
	cmp.l	#$01020304,d0
	beq.s	.c94
	failt	94
.c94:	moveq	#0,d0
	or.w	X+3,d0
	cmp.l	#$0000A3A4,d0
	beq.s	.c95
	failt	95
.c95:	movea.l	X+2,a1
	cmpa.l	#$A2A3A4A5,a1
	beq.s	.c96
	failt	96
.c96:	movea.w	X+5,a1			; $A5A6, sign-extended
	cmpa.l	#$FFFFA5A6,a1
	beq.s	.c97
	failt	97
.c97:	movem.l	X+2,d0-d1
	cmp.l	#$A2A3A4A5,d0
	bne.s	.f98
	cmp.l	#$A6A7A8A9,d1
	beq.s	.c98
.f98:	failt	98
.c98:	move.l	X+2,X+9			; memory to memory, both misaligned
	move.l	X+9,d0
	cmp.l	#$A2A3A4A5,d0
	bne.s	.f99
	move.l	X+8,d0			; {$A8, $A2A3A4}
	cmp.l	#$A8A2A3A4,d0
	bne.s	.f99
	move.l	X+12,d0			; {$A5, $ADAEAF}
	cmp.l	#$A5ADAEAF,d0
	beq.s	.c99
.f99:	failt	99
.c99:	addq.l	#1,X+2			; read-modify-write
	move.l	X+2,d0
	cmp.l	#$A2A3A4A6,d0
	bne.s	.f90
	move.l	X+4,d0			; {$A4A6, $A6A7}
	cmp.l	#$A4A6A6A7,d0
	beq.s	.c90
.f90:	failt	90
.c90:


; ---- 12x/13x (MIS): in grp1213 (code placed at $6A00: the main code must stay below $2000, the data lines)
	jsr	grp1213

; ---- 10x: translation on.  4K pages 0-15 identity except logical page 2
; -> physical $4000; the table setup of t_dcache_pipe.s.  P is written to
; the PHYSICAL homes with translation off; the tables walked, both lines
; cached through the logical address, memory patched (the DMA agent writes
; physical memory), then the probes.
	lea	XM,a0
	bsr	cacheP			; (physical $4100..$411F = P, cached by its physical name: harmless)
	lea	XWM,a0
	bsr	cacheP
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
	move.l	#$4000|1,PAGE+2*4	; logical page 2 -> physical $4000
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	cpusha	dc
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	move.l	X,d0			; the walk (its U-bit write-back snoops set 0)
	move.b	REFP,d0			; (every page the probes touch walked now: each walk's
	move.w	DMA_NS,d0		;  U-bit write-back snoops set 0, where XW's second line is)
	lea	X,a0
	bsr	cacheL			; L0, L1 by their logical names
	lea	XW,a0
	bsr	cacheL
	lea	XM,a0
	bsr	patchQ
	lea	XWM,a0
	bsr	patchQ
	PL	X,1,1,101
	PL	X,2,1,102
	PL	X,3,1,103
	PL	X,14,1,104
	PW	X,3,1,105
	PW	X,15,1,106
	PL	XW,13,1,107
	PL	XW,14,1,108
	PL	XW,15,1,109
	PW	XW,15,1,110
	; the page made cache-inhibited: nothing served any more
	move.l	#$4000|$41,PAGE+2*4	; physical $4000, CM = 10
	pflusha
	move.l	X,d0			; (walk again)
	PL	X,1,0,111
	PL	X,2,0,112
	PL	X,14,0,113
	PW	X,3,0,114
	PL	XW,14,0,115
	; back to cacheable, the ATC copy follows the new descriptor (the
	; inhibited reads invalidated the lines they hit: P cached afresh
	; through the logical address, memory patched again)
	move.l	#$4000|1,PAGE+2*4
	pflusha
	move.l	X,d0
	lea	X,a0
	bsr	cacheP
	lea	XM,a0
	bsr	patchQ
	PL	X,2,1,116
	PL	X,14,1,117
; ---- 14x (MIS, copyback): in grp14 ($6A00 section)
	jsr	grp14
; ---- 15x (MIS): a snoop over a misaligned store's second piece ($6A00 section)
	jsr	grp15
	moveq	#0,d0
	movec	d0,tc
	pflusha
	cpusha	dc

	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; the probe's verdict: d0 the value read, d2 the served (P) value, d3 the
; memory (Q) value, d4 the mode, d5 whether the build serves
chkl:	tst.w	d4
	beq.s	.m
	tst.w	d5
	beq.s	.m
	cmp.l	d2,d0
	bne	fail_all
	rts
.m:	cmp.l	d3,d0
	bne	fail_all
	rts
chkw:	tst.w	d4
	beq.s	.m
	tst.w	d5
	beq.s	.m
	cmp.w	d2,d0
	bne	fail_all
	rts
.m:	cmp.w	d3,d0
	bne	fail_all
	rts

; (MIS) helpers.  mk4: d2 = the longword of the 4 bytes at (a0); mk4b: the
; same into d3; mk2s: d2 = {(a0), 1(a0), 0, 0}; chks: d0 must be d2 with the
; feature (d5), d3 without; patchX: patchQ with the pattern at (a1)
mk4:	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	rts
mk4b:	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	rts
mk2sb:	move.b	(a0)+,d3
	lsl.l	#8,d3
	move.b	(a0)+,d3
	swap	d3
	clr.w	d3
	rts
mk2s:	move.b	(a0)+,d2
	lsl.l	#8,d2
	move.b	(a0)+,d2
	swap	d2
	clr.w	d2
	rts
chks:	tst.w	d5
	beq.s	.m
	cmp.l	d2,d0
	bne	fail_all
	rts
.m:	cmp.l	d3,d0
	bne	fail_all
	rts
patchX:	move.w	#1,DMA_NS
	moveq	#15,d1
.p:	move.w	(a1)+,DMA_D
	move.l	a0,d0
	move.w	d0,DMA_A
	move.w	#0,DMA_GO
	moveq	#50,d0
.w:	dbra	d0,.w
	addq.l	#2,a0
	dbra	d1,.p
	clr.w	DMA_NS
	rts

; wrpat: 32 bytes d0, d0+1, ... at (a0) (byte stores: write-through)
wrpat:	moveq	#31,d1
.w:	move.b	d0,(a0)+
	addq.b	#1,d0
	dbra	d1,.w
	rts

; cacheP: P written at (a0) and the two lines read in (cached)
cacheP:	move.l	a0,-(sp)
	move.w	#PBASE,d0
	bsr	wrpat
	move.l	(sp)+,a0
; cacheL: the two lines at (a0) read in
cacheL:	move.l	(a0),d0
	move.l	4(a0),d0
	move.l	8(a0),d0
	move.l	12(a0),d0
	move.l	16(a0),d0
	move.l	20(a0),d0
	move.l	24(a0),d0
	move.l	28(a0),d0
	rts

; patchQ: the DMA agent (no snoop) writes Q over the 32 bytes at (a0),
; a word at a time, behind the cache's back
patchQ:	move.w	#1,DMA_NS
	lea	REFQ,a1
	moveq	#15,d1
.p:	move.w	(a1)+,DMA_D
	move.l	a0,d0
	move.w	d0,DMA_A
	move.w	#0,DMA_GO
	moveq	#50,d0
.w:	dbra	d0,.w
	addq.l	#2,a0
	dbra	d1,.p
	clr.w	DMA_NS
	rts

; sweep7: for every delay 0..47: both longwords restored (memory and the
; cached lines agree: old), the DMA word (with its snoop) armed at d6 with
; $ABCD, then 24 reads of the longword at X+14 each checked on the spot
; (no store between them: with a store in flight the path would refuse
; anyway) -- every one the old value ($33445566) or the new one (a3), and
; once new never old; then 24 more with the samples stored (the shape of
; a copy loop), checked afterwards.
sweep7:	moveq	#0,d4			; the delay
.l7:	move.l	#$11223344,X+12
	move.l	#$55667788,X+16
	move.l	X+12,d0			; (cached again after the last snoop)
	move.l	X+16,d0
	move.l	X+14,d0			; (served: both resident)
	move.w	d6,DMA_A
	move.w	#$ABCD,DMA_D
	move.w	d4,DMA_GO
	moveq	#0,d2			; seen the new value
	jsr	(a4)
	moveq	#50,d1
.w7:	dbra	d1,.w7
	move.l	X+14,d0
	cmp.l	a3,d0
	beq.s	.c7
	failt	79			; the last read is not the new value
.c7:	; the same with the samples stored
	move.l	#$11223344,X+12
	move.l	#$55667788,X+16
	move.l	X+12,d0
	move.l	X+16,d0
	move.l	X+14,d0
	move.w	d6,DMA_A
	move.w	#$ABCD,DMA_D
	move.w	d4,DMA_GO
	lea	BUF,a1
	bsr	swp7s
	moveq	#50,d1
.w7b:	dbra	d1,.w7b
	lea	BUF,a1
	moveq	#23,d1
	moveq	#0,d2
.s7:	move.l	(a1)+,d0
	cmp.l	a3,d0
	beq.s	.new7
	cmp.l	#$33445566,d0
	beq.s	.old7
	failt	77			; neither: a torn read
.old7:	tst.b	d2
	beq.s	.n7
	failt	78			; old after new
.new7:	st	d2
.n7:	dbra	d1,.s7
	addq.l	#1,d4
	cmp.l	#48,d4
	bne	.l7
	rts
; one sample, checked on the spot (d2: the new value has been seen)
SAMP	macro
	move.l	X+14,d0
	cmp.l	a3,d0
	beq.s	.n\@
	cmp.l	#$33445566,d0
	bne	.torn
	tst.b	d2
	bne	.back
	bra.s	.d\@
.n\@:	st	d2
.d\@:
	endm
swp7:	rept	24
	SAMP
	endr
	rts
.torn:	failt	75			; neither old nor new: a torn read
.back:	failt	76			; old after new
swp7s:	rept	24
	move.l	X+14,(a1)+
	endr
	rts

; ---- MIS groups, placed above the data lines (page 6, identity mapped)
	org	$6A00
; peekl: d0 = the longword memory holds at d1.w (the bench's peek registers,
; $F190/$F192/$F194).  Their line is cacheable here and keeps an old copy:
; a chipset word write with its snoop to the unused $F19E drops that set's
; clean lines first, so the peek reads miss and fill afresh.
peekl:	move.w	d1,PEEK_A
	move.w	#$F19E,DMA_A
	clr.w	DMA_D
	clr.w	DMA_GO
	moveq	#20,d0
.w:	dbra	d0,.w
	move.w	PEEK_D0,d0
	swap	d0
	move.w	PEEK_D1,d0
	rts

grp1213:
; ---- 12x (MIS): a misaligned STORE merges into the resident lines instead
; of clearing their rows.  Lines cached with P, memory Q behind the cache,
; then a misaligned store S; an aligned read of a longword the store touched
; gives {P.., S..} from the line with the feature (the line stayed resident),
; {Q.., S..} without it (the row was cleared, the read refilled from memory).
; Memory (peeked) holds {Q.., S..} either way: the memory transfer of the
; store is unchanged.  A word store at an odd offset (one longword) too.
	cpusha	dc
	lea	X,a0
	bsr	cacheP
	lea	X,a0
	bsr	patchQ
	move.l	#$11223344,X+2		; inside L0
	move.l	#$55667788,X+14		; across L0/L1
	move.w	#$99AA,X+21		; odd word inside one longword
	moveq	#7,d1
.w12:	dbra	d1,.w12
	move.w	#121,d7
	move.l	X,d0
	lea	REFP,a0
	bsr	mk2s			; d2 = {P0,P1,$11,$22}
	move.w	#$1122,d2
	lea	REFQ,a0
	bsr	mk2sb
	move.w	#$1122,d3
	bsr	chks
	move.w	#122,d7
	move.l	X+4,d0
	move.l	#$33440000,d2
	move.w	REFP+6,d2
	move.l	#$33440000,d3
	move.w	REFQ+6,d3
	bsr	chks
	move.w	#123,d7
	move.l	X+12,d0
	lea	REFP+12,a0
	bsr	mk2s
	move.w	#$5566,d2
	lea	REFQ+12,a0
	bsr	mk2sb
	move.w	#$5566,d3
	bsr	chks
	move.w	#124,d7
	move.l	X+16,d0
	move.l	#$77880000,d2
	move.w	REFP+18,d2
	move.l	#$77880000,d3
	move.w	REFQ+18,d3
	bsr	chks
	move.w	#125,d7
	move.l	X+20,d0
	moveq	#0,d2
	move.b	REFP+20,d2
	lsl.l	#8,d2
	lsl.l	#8,d2
	move.w	#$99AA,d2
	lsl.l	#8,d2
	move.b	REFP+23,d2
	moveq	#0,d3
	move.b	REFQ+20,d3
	lsl.l	#8,d3
	lsl.l	#8,d3
	move.w	#$99AA,d3
	lsl.l	#8,d3
	move.b	REFQ+23,d3
	bsr	chks
	; memory: the whole store went out
	move.w	#126,d7
	move.w	#X,d1
	bsr	peekl
	lea	REFQ,a0
	bsr	mk2s
	move.w	#$1122,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#127,d7
	move.w	#X+12,d1
	bsr	peekl
	lea	REFQ+12,a0
	bsr	mk2s
	move.w	#$5566,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#128,d7
	move.w	#X+16,d1
	bsr	peekl
	move.l	#$77880000,d2
	move.w	REFQ+18,d2
	cmp.l	d2,d0
	bne	fail_all

; ---- 13x (MIS): a misaligned READ that misses fills the line(s).  Lines
; not resident, memory Q; a misaligned read inside L0 and one across L0/L1
; (right values), then memory changed to R behind the cache: aligned reads
; of both lines give Q with the feature (served from the filled lines), R
; without it (nothing was filled).
	cpusha	dc
	lea	X,a0
	move.w	#QBASE,d0
	bsr	wrpat
	move.w	#131,d7
	move.l	X+2,d0
	lea	REFQ+2,a0
	bsr	mk4
	cmp.l	d2,d0
	bne	fail_all
	move.w	#132,d7
	move.l	X+14,d0
	lea	REFQ+14,a0
	bsr	mk4
	cmp.l	d2,d0
	bne	fail_all
	lea	X,a0
	lea	REFR,a1
	bsr	patchX
	move.w	#133,d7
	move.l	X,d0
	lea	REFQ,a0
	bsr	mk4
	lea	REFR,a0
	bsr	mk4b
	bsr	chks
	move.w	#134,d7
	move.l	X+16,d0
	lea	REFQ+16,a0
	bsr	mk4
	lea	REFR+16,a0
	bsr	mk4b
	bsr	chks
	move.w	#135,d7
	move.l	X+8,d0
	lea	REFQ+8,a0
	bsr	mk4
	lea	REFR+8,a0
	bsr	mk4b
	bsr	chks
	; LW1's fill must write LW1's row image back: a decoy (R) in way 0 of
	; L1's set, L0 in way 0 of its own; the read across fills L1 into way
	; 1 -- with L0's row image copied there, way 0 would hit X+16 with R
	cpusha	dc
	lea	X,a0
	move.w	#QBASE,d0
	bsr	wrpat
	move.l	DEC1,d0			; set $11 way 0: the decoy
	move.l	X,d0			; set $10 way 0: L0
	move.w	#136,d7
	move.l	X+14,d0			; LW0 hits, LW1 fills (way 1)
	lea	REFQ+14,a0
	bsr	mk4
	cmp.l	d2,d0
	bne	fail_all
	move.w	#137,d7
	move.l	X+16,d0
	lea	REFQ+16,a0
	bsr	mk4
	cmp.l	d2,d0
	bne	fail_all


	rts

grp14:
; ---- 14x (MIS, copyback builds only: $F196; translation on, logical page 2
; made copyback, CM = 01, physical $4000): a misaligned store to a
; copyback page whose two pieces both hit stays in the cache (memory not
; written until CPUSHA); one whose second piece misses is written to memory
; whole, the hitting line merged.
	tst.w	CBFEAT
	beq	.no14
	move.l	#$4000|$21,PAGE+2*4	; copyback
	pflusha
	cpusha	dc
	move.l	X,d0			; (walk; L0 now resident)
	lea	X,a0
	bsr	cacheP			; P (copyback: into the resident L0, dirty)
	cpusha	dc			; memory P
	lea	X,a0
	bsr	cacheL			; L0 and L1 resident, clean
	move.l	#$11223344,X+6		; inside L0 (bytes 6..9)
	moveq	#20,d1
.w14:	dbra	d1,.w14
	move.w	#141,d7
	move.w	#XM+4,d1
	bsr	peekl
	lea	REFP+4,a0
	bsr	mk4			; d2 = P4..P7 (not written: both pieces hit)
	move.l	d2,d3
	move.w	#$1122,d3		; (without the feature: written through)
	bsr	chks
	move.w	#142,d7
	move.l	X+4,d0
	lea	REFP+4,a0
	bsr	mk4
	move.w	#$1122,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#143,d7
	move.l	X+8,d0
	lea	REFP+8,a0
	bsr	mk4
	swap	d2
	move.w	#$3344,d2
	swap	d2
	cmp.l	d2,d0
	bne	fail_all
	cpusha	dc			; the dirty line reaches memory
	move.w	#144,d7
	move.w	#XM+4,d1
	bsr	peekl
	lea	REFP+4,a0
	bsr	mk4
	move.w	#$1122,d2
	cmp.l	d2,d0
	bne	fail_all
	; L0 resident only, a store across L0/L1
	lea	X,a0
	move.w	#PBASE,d0
	bsr	wrpat
	cpusha	dc
	move.l	X,d0
	move.l	X+4,d0
	move.l	X+8,d0
	move.l	X+12,d0
	move.l	#$55667788,X+14
	moveq	#20,d1
.w14b:	dbra	d1,.w14b
	move.w	#145,d7
	move.w	#XM+12,d1
	bsr	peekl
	lea	REFP+12,a0
	bsr	mk4
	move.w	#$5566,d2
	cmp.l	d2,d0			; written whole (the second piece missed)
	bne	fail_all
	move.w	#146,d7
	move.w	#XM+16,d1
	bsr	peekl
	move.l	#$77880000,d2
	move.w	REFP+18,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#147,d7
	move.l	X+12,d0
	lea	REFP+12,a0
	bsr	mk4
	move.w	#$5566,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#148,d7
	move.l	X+16,d0
	move.l	#$77880000,d2
	move.w	REFP+18,d2
	cmp.l	d2,d0
	bne	fail_all
	; L1 resident only: the first piece misses, the second merges (dirty);
	; memory is written whole all the same
	cpusha	dc
	lea	X,a0
	move.w	#PBASE,d0
	bsr	wrpat			; memory P (nothing resident: no allocate)
	cpusha	dc
	move.l	X+16,d0
	move.l	X+20,d0
	move.l	X+24,d0
	move.l	X+28,d0
	move.l	#$55667788,X+14
	moveq	#20,d1
.w14c:	dbra	d1,.w14c
	move.w	#149,d7
	move.w	#XM+12,d1
	bsr	peekl
	lea	REFP+12,a0
	bsr	mk4
	move.w	#$5566,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#140,d7
	move.w	#XM+16,d1
	bsr	peekl
	move.l	#$77880000,d2
	move.w	REFP+18,d2
	cmp.l	d2,d0
	bne	fail_all
	cpusha	dc
.no14:	rts

grp15:
; ---- 15x (MIS): a chipset write (DMA with its snoop) to the SET of the
; SECOND line of a line-crossing misaligned store, landing 0..47 clocks
; after it is armed, across a burst of eight stores to X+14 (L0 bytes
; 14-15, L1 bytes 16-17).  The DMA word goes to physical DEC1 ($2510, set
; $11 like L1, a line nothing caches): its snoop drops L1 while it is clean
; and spares it once a store made it dirty (copyback) -- a DMA write INTO a
; dirty copyback line is outside this design (only the CPU writes the
; copyback window).  Translation on, logical page 2 -> physical $4000;
; copyback (CM = 01) in copyback builds, write-through otherwise.  Whatever
; the order, afterwards the cache and memory agree on the last store's
; bytes, read through the cache and, after CPUSHA, peeked in memory.  A merge of the
; second piece into a line the snoop just dropped -- a dirty bit on an
; invalid way (copyback) -- loses the store's L1 bytes (st_snooped2 and the
; merge clock's own snoop check, ap040_cache.v st_merge2).
	move.l	#$4000|1,PAGE+2*4	; write-through
	tst.w	CBFEAT
	beq.s	.wt15
	move.l	#$4000|$21,PAGE+2*4	; copyback
.wt15:	pflusha
	cpusha	dc
	move.l	X,d0			; (walk)
	moveq	#0,d4			; the delay
.l15:	move.l	#$11223344,X+12
	move.l	#$55667788,X+16
	move.l	#$99AABBCC,X+28
	cpusha	dc			; memory has them, nothing resident
	move.l	X+12,d0			; L0 and L1 resident, clean
	move.l	X+16,d0
	move.l	#$A1B2C3D4,d6
	move.w	#DEC1,DMA_A
	move.w	#$DDEE,DMA_D
	move.w	d4,DMA_GO
	rept	8
	move.l	d6,X+14
	add.l	#$01010101,d6
	endr
	sub.l	#$01010101,d6		; the last value stored
	moveq	#30,d1
.w15:	dbra	d1,.w15
	move.w	#151,d7
	move.l	X+12,d0			; {$11, $22, last[31:16]}
	move.l	d6,d2
	swap	d2
	and.l	#$FFFF,d2
	or.l	#$11220000,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#152,d7
	move.l	X+16,d0			; {last[15:0], $77, $88}
	move.l	d6,d2
	swap	d2
	clr.w	d2
	or.w	#$7788,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#153,d7
	move.l	X+28,d0
	cmp.l	#$99AABBCC,d0
	bne	fail_all
	cpusha	dc			; dirty lines (copyback) reach memory
	move.w	#154,d7
	move.w	#XM+12,d1
	bsr	peekl
	move.l	d6,d2
	swap	d2
	and.l	#$FFFF,d2
	or.l	#$11220000,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#155,d7
	move.w	#XM+16,d1
	bsr	peekl
	move.l	d6,d2
	swap	d2
	clr.w	d2
	or.w	#$7788,d2
	cmp.l	d2,d0
	bne	fail_all
	move.w	#156,d7
	move.w	#XM+28,d1
	bsr	peekl
	cmp.l	#$99AABBCC,d0
	bne	fail_all
	addq.l	#1,d4
	cmp.l	#48,d4
	bne	.l15
	move.l	#$4000|1,PAGE+2*4
	pflusha
	cpusha	dc
	rts
