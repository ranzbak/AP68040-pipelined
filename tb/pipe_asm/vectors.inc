; vectors.inc - common vector table for the pipe_asm programs.
; ISP = $1F00, PC = start; every vector -> unexp except the ones a
; program overrides by defining the symbols below before including this
; (v_berr/v_divz/v_chk/v_trapv are optional).
	ifnd	v_berr
v_berr	equ	unexp
	endif
	ifnd	v_divz
v_divz	equ	unexp
	endif
	ifnd	v_chk
v_chk	equ	unexp
	endif
	ifnd	v_trapv
v_trapv	equ	unexp
	endif
	ifnd	v_fpun
v_fpun	equ	unexp		; 55 FP unsupported data type (plan M10.1)
	endif
	ifnd	v_fparith
v_fparith equ	unexp		; 48-54 the enabled FP arithmetic traps (M10.3)
	endif
	org	0
	dc.l	$1F00
	dc.l	start
	dc.l	v_berr		; 2 access error
	dc.l	v_adr		; 3 address error
	dc.l	v_ill		; 4 illegal
	dc.l	v_divz		; 5 divide by zero
	dc.l	v_chk		; 6 CHK/CHK2
	dc.l	v_trapv		; 7 TRAPcc/TRAPV
	dc.l	v_prv		; 8 privilege
	dc.l	unexp		; 9 trace
	dc.l	v_alin		; 10 A-line
	dc.l	v_flin		; 11 F-line
	rept	2
	dc.l	unexp		; 12-13
	endr
	dc.l	v_fmt		; 14 format error
	rept	17
	dc.l	unexp		; 15-31
	endr
	dc.l	v_trp0		; 32 TRAP #0
	rept	15
	dc.l	unexp		; 33-47
	endr
	rept	7
	dc.l	v_fparith	; 48-54 BSUN, INEX, DZ, UNFL, OPERR, OVFL, SNAN
	endr
	dc.l	v_fpun		; 55 FP unsupported data type
	rept	200
	dc.l	unexp		; 56-255
	endr
