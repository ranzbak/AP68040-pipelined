; double_fault.s - plan M6 tb_ap040_pipe_double_fault: a bus error on a
; store of an exception frame is a double fault -- the core halts
; (M68040UM 7.6.3, p. 7-43: "Only an external reset operation can restart
; a halted processor").  TRAP #0 pushes its frame at $1ef8..$1eff; the
; bench rejects the write to $1efc.  Bus mode only.
; expect-berr: 1efc w
; expect-halted
; expect-mem: m32 7000
v_trp0	equ	h_trap
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_berr	equ	h_berr
	include	"vectors.inc"

	org	$400
start:
	move.l	#$11111111,($7000).l
	trap	#0
	move.l	#$22222222,($7000).l	; never: the core halted
halt:
	bra.s	halt
h_trap:	rte
h_berr:	move.l	#$33333333,($7000).l	; never: the frame push faulted
	rte
unexp:
	bra.s	unexp
