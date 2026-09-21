; scc_mem.s - plan M2 tb_ap040_pipe_scc_mem: Scc to memory (a byte, no read
; of the destination), all 16 conditions over several CCR values, and to Dn
; (low byte only).
; expect-mem: m32 1300 m32 1304 m32 1308 m32 130c m32 1310 m32 1314 m32 1318 m32 131c m32 1320 m32 1324 m32 1328 m32 132c m32 1330 m32 1334 m32 1338 m32 133c m32 1340 m32 1344 m32 1348 m32 134c
; expect-noread: 1300 1310 1320 1330
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
	movea.l	#out,a0
	move.w	#$00,ccr
	bsr.s	all16
	move.w	#$04,ccr
	bsr.s	all16
	move.w	#$0A,ccr
	bsr.s	all16
	move.w	#$05,ccr
	bsr.s	all16
	move.w	#$1F,ccr
	bsr.s	all16
	move.l	#$12345678,d3
	move.w	#$04,ccr
	seq	d3			; low byte $FF, rest kept
	sne	d4
halt:
	bra.s	halt
all16:
	st	(a0)+
	sf	(a0)+
	shi	(a0)+
	sls	(a0)+
	scc	(a0)+
	scs	(a0)+
	sne	(a0)+
	seq	(a0)+
	svc	(a0)+
	svs	(a0)+
	spl	(a0)+
	smi	(a0)+
	sge	(a0)+
	slt	(a0)+
	sgt	(a0)+
	sle	(a0)+
	rts
unexp:
	bra.s	unexp

	org	$1300
out:	dcb.b	96,$5A
