; reset_vec.s - the reset exception: ISP from vector 0, PC from vector 1
; (M68040UM 8.2.10 p. 8-17), SR = $2700.  Unusual values so a core that
; starts at a fixed address or leaves ISP at 0 fails.  Plan M1
; tb_ap040_pipe_reset_vec.
	org	0
	dc.l	$1A2C		; ISP
	dc.l	start		; PC ($0600)
	rept	254
	dc.l	unexp
	endr

	org	$600
start:
	move.l	a7,d0		; $1A2C
	move.l	#$C0DE,-(a7)	; pushes onto the loaded ISP
	move.l	a7,d1		; $1A28
halt:
	bra.s	halt
unexp:
	moveq	#-1,d7
	bra.s	unexp
