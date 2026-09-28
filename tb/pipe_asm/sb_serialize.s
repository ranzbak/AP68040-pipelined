; sb_serialize.s - findings/storebuf/plan.md stage 0: a serialising
; instruction starts only once every older store is in memory, the posted
; ones included (M68040UM 7.7; a MOVEC to TC or a DTTx must not change the
; translation of a store still in the FIFO).  Each one follows posted
; stores and is a "syncpc": when it retires no store may be posted (bus
; legs).  A TRAP's handler and a RESET's successor read back what was
; stored.  Hand-computed.
; diff: --cycles 30000
v_adr	equ	unexp
v_ill	equ	unexp
v_prv	equ	unexp
v_alin	equ	unexp
v_flin	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	h_trap
	include	"vectors.inc"

	org	$400
start:
	lea	$6000,a0
	moveq	#0,d0
; MOVEC to VBR, CACR, DTT0, TC (all zero: nothing changes but the order)
	move.l	#$01010101,(a0)+
	move.l	#$02020202,(a0)+
s1:	movec	d0,vbr
	move.l	#$03030303,(a0)+
	move.l	#$04040404,(a0)+
s2:	movec	d0,cacr
	move.l	#$05050505,(a0)+
	move.l	#$06060606,(a0)+
s3:	movec	d0,dtt0
	move.l	#$07070707,(a0)+
	move.l	#$08080808,(a0)+
s4:	movec	d0,tc
; CINVA, MOVE to SR, ORI to SR
	move.l	#$09090909,(a0)+
	move.l	#$0a0a0a0a,(a0)+
s5:	cinva	bc
	move.l	#$0b0b0b0b,(a0)+
	move.l	#$0c0c0c0c,(a0)+
s6:	move.w	#$2700,sr
	move.l	#$0d0d0d0d,(a0)+
	move.l	#$0e0e0e0e,(a0)+
s7:	ori.w	#$0700,sr
; RTE to the next instruction, the frame pushed by posted stores
	move.l	#$0f0f0f0f,(a0)+
	move.w	#$0000,-(sp)		; format $0
	pea	after_rte
	move.w	#$2700,-(sp)
s8:	rte
after_rte:
; TRAP: the handler reads what was stored before it
	move.l	#$10101010,(a0)+
	move.l	#$11111111,(a0)+
	trap	#0
; RESET, then read back
	move.l	#$12121212,(a0)+
	move.l	#$13131313,(a0)+
s9:	reset
	move.l	-4(a0),d2		; 13131313
halt:	bra.s	halt

h_trap:	move.l	-4(a0),d1		; 11111111
	add.l	-8(a0),d1		; 21212121
	rte

unexp:	bra.s	unexp

	org	$6000
	dcb.l	32,$eeeeeeee
