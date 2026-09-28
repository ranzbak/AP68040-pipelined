; fpureal_perf.s - a cycle budget for register-to-register FP instructions
; (perf work 2026-09-28: the FPU handshake).  A dependent chain of 64
; FMOVE.X FP1,FP2 and 64 FADD.X FP1,FP2; the .exp maxclk is the budget the
; core has been measured to meet, and fp2 the result (1 + 64 x 3 = 193).
; diff: --cycles 20000
v_flin	equ	unexp
v_fpun	equ	unexp
v_fmt	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_trp0	equ	unexp
	include	"vectors.inc"
	org	$400
start:	fmove.l	#3,fp1
	fmove.l	#1,fp2
	nop
	rept	64
	fmove.x	fp1,fp2
	endr
	fmove.l	#1,fp2
	rept	64
	fadd.x	fp1,fp2
	endr
	fmove.l	fp2,$7000
halt:	bra.s	halt
unexp:	bra.s	unexp
