; rte_formats.s - plan M6 tb_ap040_pipe_rte_formats: RTE pops format $0 (8
; bytes), $2 and $3 (12), $4 (16, the LC040 build), $7 (60), processes a $1
; throwaway frame and then the frame below it, takes a format error (vector
; 14, format $0, PC = the RTE, the bad frame left in place) on $B, and in
; user mode is a privilege violation.  Each case records SP after the RTE.
; diff: --cycles 40000
; expect-range: 7000 7040
v_fmt	equ	h_fmt
v_prv	equ	h_prv
v_adr	equ	unexp
v_ill	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"

frame	macro	; \1 = format/vector word, \2 = extra longwords, \3 = return label
	rept	\2
	clr.l	-(sp)
	endr
	move.w	#\1,-(sp)
	pea	\3(pc)
	move.w	#$2700,-(sp)
	rte
	endm

	org	$400
start:
	movea.l	#$7000,a6
	frame	$0000,0,r0
r0:	move.l	sp,(a6)+		; $1F00
	frame	$2008,1,r2
r2:	move.l	sp,(a6)+
	frame	$3008,1,r3
r3:	move.l	sp,(a6)+
	frame	$4008,2,r4
r4:	move.l	sp,(a6)+
	frame	$7008,13,r7
r7:	move.l	sp,(a6)+
	; $1: the throwaway frame, then the $0 frame below it
	move.w	#$0000,-(sp)
	pea	r1(pc)
	move.w	#$2700,-(sp)
	move.w	#$1000,-(sp)
	pea	unexp(pc)		; the $1 frame's PC is not used
	move.w	#$2700,-(sp)
	rte
r1:	move.l	sp,(a6)+
	; a format error: vector 14, the frame stays
	frame	$B008,0,unexp
fmt_back:
	move.l	sp,(a6)+		; the handler returned past the bad frame
	; user mode: RTE is privileged
	movea.l	#$6000,a0
	move	a0,usp
	move.w	#$0000,sr
	rte				; vector 8
prv_back:
	move.l	sp,(a6)+
	move.w	sr,d0
	move.l	d0,(a6)+
halt:
	bra.s	halt

h_fmt:	move.w	6(sp),(a6)+		; $0038
	move.l	2(sp),(a6)+		; the RTE's PC
	lea	8(sp),sp		; drop the format-error frame
	lea	8(sp),sp		; and the bad frame
	bra	fmt_back
h_prv:	move.w	6(sp),(a6)+		; $0020
	lea	8(sp),sp		; drop the frame: stay in supervisor mode
	bra	prv_back
unexp:
	bra.s	unexp
