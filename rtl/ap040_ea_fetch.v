//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_ea_fetch.v - <ea> fetch stage (rewritten for Minimig plan M1)      //
//                                                                          //
// Owns the data-read port and every multi-access sequence:                 //
//   ordinary instruction: memory-indirect pointer fetches (src, then dst),  //
//     the source operand load, the destination load of a read-modify-write, //
//     register operand reads; then one micro-op to EX.                      //
//   exception entry (TRAP, illegal, A/F-line, privilege, address error,    //
//     format error): waits until every older instruction has committed      //
//     (so SR and the stack pointers are architectural), then sends the      //
//     frame stores, reads the vector at VBR + 4*vector, and sends a final   //
//     micro-op that writes SP and SR and redirects to the handler.  The     //
//     stores go down the pipe like any store and are written in WB, so a    //
//     frame is never written for an instruction that is later flushed.      //
//   RTE: pops SR, PC, format word; checks the format (M68040UM 8.4, p. 8-20: //
//     $0/$1/$2/$3/$4/$7; anything else is a format error, vector 14); the   //
//     final micro-op writes SR and SP and redirects.  $1 pops its 8 bytes,  //
//     commits the SR it held and then processes the frame the new SR's      //
//     stack holds.                                                         //
//   reset (RESET_FROM_VECTORS): ISP <- (0), PC <- (4).                     //
//                                                                          //
// Exceptions are all taken here, never in EX: a branch to an odd address  //
// is converted in ID, JMP/JSR/RTS odd targets here.                         //
//                                                                          //
// Memory reads are single-clock requests (rd_req) answered by rd_ack some  //
// clocks later (the L1 model: the next clock).  A read waits while EX      //
// holds an older store (it has not reached memory yet); a store in WB is    //
// written in the same clock the read samples, write first, by the memory. //
//                                                                          //
// Coding rule (Icarus): combinational logic is pure functions of their     //
// arguments, assigned with assign -- see ap040_decode.v.                   //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_ea_fetch
	import ap040_pipe_pkg::*;
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EX cannot accept this cycle
	input             flush,

	input             eac_valid,
	input  eac_t      eac_i,

	input      [15:0] sr_in,      // architectural SR (WB write-through)
	input      [31:0] vbr_in,
	input       [2:0] sfc_in, dfc_in,   // MOVES
	input             older_busy, // EX or WB holds an instruction
	input             older_store,// EX holds a store that has not reached memory
	input             reset_seq,  // run the reset vector fetch first
	// EA-calc's early read for the instruction moving in at the end of this
	// clock (issued when this stage does not use the port itself)
	input             early_v,
	input  rdreq_t    early,

	// register reads (with the regfile's WB write-through)
	output      [4:0] ra_a, ra_b, ra_c, ra_d,
	input      [31:0] rd_a, rd_b, rd_c, rd_d,
	// EX-stage writes, forwarded
	input             ex_w0_v, input [4:0] ex_w0_r, input [31:0] ex_w0_val,
	input             ex_u0_v, input [4:0] ex_u0_r, input [31:0] ex_u0_val,
	input             ex_u1_v, input [4:0] ex_u1_r, input [31:0] ex_u1_val,
	input             ex_ccr_v, input [4:0] ex_ccr,   // the CCR EX's micro-op leaves

	// data read port
	output            rd_req,
	output     [31:0] rd_addr,
	output      [1:0] rd_size,
	output      [2:0] rd_fc,      // the read's function code (MOVES: SFC)
	input             rd_ack,
	input      [31:0] rd_data_raw,
	// the older stores not yet in memory when a read sampled it: the one in
	// WB now (it was in EX then) and the one in EX now (it was here then)
	input             wb_st_v, input [31:0] wb_st_addr, input [1:0] wb_st_size, input [31:0] wb_st_data,
	input             ex_st_v, input [31:0] ex_st_addr, input [1:0] ex_st_size, input [31:0] ex_st_data,

	output            eaf_stall,  // to EA-calc: the current instruction is not done
	output            eaf_blk,    // current instruction is serialising / sequenced

	output reg        eaf_valid,
	output ex_t       eaf_o,
	output            halted,

	// redirect from this stage: RTS (its return address is loaded here) and
	// a JMP/JSR whose target needed a memory-indirect pointer
	output            eaf_redir_v,
	output     [31:0] eaf_redir_pc
);

wire id_t i = eac_i.i;

//--------------------------------------------------------------- state
localparam [3:0] P_START = 4'd0,  // examine / wait for serialisation
                 P_OPS   = 4'd1,  // ordinary instruction: memory reads
                 P_EXC   = 4'd2,  // exception entry
                 P_RTE   = 4'd3,
                 P_RESET = 4'd4,
                 P_HALT  = 4'd5,
                 P_MOVEM = 4'd6;  // MOVEM: one micro-op per register

reg  [3:0] ph;
reg        rd_pend;        // a read is outstanding
reg        rd_drop;        // ... and belongs to a flushed instruction
reg  [2:0] rd_tag;         // which read it is
reg        done_smi, done_dmi, done_sld, done_dld;
reg [31:0] s_addr, d_addr; // after memory indirect
reg [31:0] s_val, d_val;   // loaded operands
reg        rst_pending;    // reset sequence still to run

// exception parameters (latched when an exception sequence starts)
reg  [7:0] x_vec;
reg  [3:0] x_fmt;
reg [31:0] x_pc, x_addr;
reg  [2:0] x_step;         // 0-2 frame stores, 3 vector read, 4 final, 5 wait + latch SR/SP
reg [15:0] x_sr;           // SR stacked
reg [31:0] x_sp;           // new SP (reset: the loaded ISP)
reg  [4:0] x_bank;
reg [31:0] x_target;

// RTE / reset
reg  [2:0] r_step;
reg [15:0] r_sr;
reg [31:0] r_pc;
reg [15:0] r_fv;

wire       s_bit    = sr_in[13];
wire [4:0] bank_now = sr_in[12] ? R_MSP : R_ISP;   // supervisor stack the SR selects

//--------------------------------------------------------------- operand reads
function automatic logic [4:0] ra_a_f(input logic [3:0] p, input eac_t e, input logic [4:0] bank);
	if (p == P_EXC || p == P_RTE) return bank;       // the supervisor stack pointer
	if (e.i.cls == CL_CAS2) return {2'b00, e.i.ext[2:0]};    // Dc1 (the source is (Rn1))
	if (e.i.cls == CL_MOVEC && !e.i.imm[4])         // Rc -> Rn: an SP selector reads the physical SP
		return (e.i.imm[3:0] == CR_USP) ? R_USP : (e.i.imm[3:0] == CR_ISP) ? R_ISP : R_MSP;
	return e.src_r;
endfunction

assign ra_a = ra_a_f(ph, eac_i, bank_now);
assign ra_b = (eac_i.i.cls == CL_CAS2) ? {2'b00, eac_i.i.ext2[2:0]} : eac_i.dst_r;   // CAS2: Dc2

function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] rf,
                                    input logic w0v, input logic [4:0] w0r, input logic [31:0] w0d,
                                    input logic u0v, input logic [4:0] u0r, input logic [31:0] u0d,
                                    input logic u1v, input logic [4:0] u1r, input logic [31:0] u1d);
	if (w0v && w0r == r) return w0d;
	if (u1v && u1r == r) return u1d;
	if (u0v && u0r == r) return u0d;
	return rf;
endfunction

wire [31:0] op_a = fwd(ra_a, rd_a, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
// the destination register sees this instruction's own source update
// the third register operand (CAS Du, DIV.L Dr): no A7, no own update
assign ra_c = (eac_i.i.cls == CL_MOVEM) ? mm_sreg : eac_i.i.reg_c;   // MOVEM: the register being stored
wire [31:0] op_c = fwd(ra_c, rd_c, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
// the fourth (bitfield width in Dn)
assign ra_d = eac_i.i.reg_d;
wire [31:0] op_d = fwd(ra_d, rd_d, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
wire [31:0] op_b = (eac_i.u0_v && eac_i.u0_r == ra_b) ? eac_i.u0_val :
                   fwd(ra_b, rd_b, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);

//--------------------------------------------------------------- bitfields
// M68040UM / PRM BFxxx: offset = Do ? Dn (signed, 32 bits) : ext[10:6];
// width = Dw ? Dn mod 32 : ext[4:0], 0 meaning 32.  Memory: the field
// starts at bit (offset mod 8) of the byte at <ea> + (offset >> 3), and
// spans 1-5 bytes.  Reads as the reference core (lib/AP68040 S_BF_MEM0):
// a longword, plus the fifth byte for a 5-byte span; writes B / W / W+B /
// L / L+B by span (S_BF_WR1/2).
wire        is_bf   = (i.cls == CL_BF);
wire        bf_mem  = is_bf && (i.dst.kind == EK_MEM);
// Offset and width come from the register file (WB write-through), not
// from EX: a bitfield waits while EX is writing one of its registers
// (bf_rdblk, vhold below), so the read address and the span -- which decide
// reads and micro-ops -- stay off EX's result path (timing, plan M3).
wire [31:0] bf_off  = (i.reg_c != R_NONE) ? rd_c : {27'd0, i.ext[10:6]};
wire  [4:0] bf_w5   = (i.reg_d != R_NONE) ? rd_d[4:0] : i.ext[4:0];
wire  [5:0] bf_w    = (bf_w5 == 5'd0) ? 6'd32 : {1'b0, bf_w5};
wire [31:0] bf_addr = eac_i.dst_ea + {{3{bf_off[31]}}, bf_off[31:3]};
wire  [6:0] bf_bits = {4'd0, bf_off[2:0]} + {1'b0, bf_w} + 7'd7;
wire  [2:0] bf_n    = bf_bits[5:3];               // 1..5 bytes
wire        bf_modify = (i.alu[2:0] == 3'd2) || (i.alu[2:0] == 3'd4) || (i.alu[2:0] == 3'd6) || (i.alu[2:0] == 3'd7);
// a second store (the byte past a word or longword) needs a second micro-op
wire        bf_two  = bf_mem && bf_modify && (bf_n == 3'd3 || bf_n == 3'd5);

//--------------------------------------------------------------- ordinary instructions
wire addr_only    = (i.cls == CL_JMP || i.cls == CL_JSR || i.cls == CL_LEA || i.cls == CL_PEA);
wire needs_ld_src = ((i.src.kind == EK_MEM) && !addr_only && i.cls != CL_MOVEM) || (bf_mem && bf_n == 3'd5);
// CHK2/CMP2 read the upper bound from <ea>+size into the "destination" load
wire needs_ld_dst = ((i.dst.kind == EK_MEM) && i.rmw && i.cls != CL_MOVEM) || (i.cls == CL_CHK2) || bf_mem;
wire need_smi = (i.src.kind == EK_MEM) && (i.src.mi != MI_NONE);
wire need_dmi = (i.dst.kind == EK_MEM) && (i.dst.mi != MI_NONE);

wire [31:0] s_addr_now = done_smi ? s_addr : eac_i.src_ea;
wire [31:0] d_addr_now = done_dmi ? d_addr :
                         (i.cls == CL_CHK2) ? s_addr_now + ((i.size == SZ_B) ? 32'd1 : (i.size == SZ_W) ? 32'd2 : 32'd4) :
                         eac_i.dst_ea;

// next read the instruction needs: {valid, tag, addr, size}
function automatic rdreq_t next_rd(input logic nsmi, input logic dsmi, input logic ndmi, input logic ddmi,
                                   input logic nsld, input logic dsld, input logic ndld, input logic ddld,
                                   input logic [31:0] sea, input logic [31:0] dea,
                                   input logic [31:0] sa, input logic [31:0] da, input logic [1:0] sz,
                                   input logic [1:0] dsz);
	rdreq_t r;
	r = '0; r.sz = SZ_L;
	if (nsmi && !dsmi)      begin r.v = 1'b1; r.t = T_SMI; r.a = sea; end
	else if (ndmi && !ddmi) begin r.v = 1'b1; r.t = T_DMI; r.a = dea; end
	else if (nsld && !dsld) begin r.v = 1'b1; r.t = T_SLD; r.a = sa; r.sz = sz; end
	else if (ndld && !ddld) begin r.v = 1'b1; r.t = T_DLD; r.a = da; r.sz = dsz; end
	return r;
endfunction

// RTR's second read (the PC at 2(SP)) is a long, its first (the CCR) a word
// a bitfield's longword at the field address, its fifth byte as the "source"
wire rdreq_t nx = next_rd(need_smi, done_smi, need_dmi, done_dmi, needs_ld_src, done_sld, needs_ld_dst, done_dld,
                          eac_i.src_ea, eac_i.dst_ea,
                          is_bf ? bf_addr + 32'd4 : s_addr_now, is_bf ? bf_addr : d_addr_now,
                          is_bf ? SZ_B : i.size,
                          (i.cls == CL_CHK2) ? i.size : is_bf ? SZ_L : i.size2);

// Store-to-load forwarding.  The memory answers with what it held at the
// clock edge ending the read's issue clock (a store committing on that edge
// included, write first).  Older stores still in flight then are now in WB
// and EX; their bytes are merged in, WB's first, then EX's (the younger).
// So a load never waits for an older store (M68040UM 10.6: ADD Dn,(An) one
// clock back to back).
reg  [31:0] rd_a_q;        // address and size of the outstanding read
reg   [1:0] rd_sz_q;
wire [31:0] rd_data = st_merge(st_merge(rd_data_raw, rd_a_q, rd_sz_q, wb_st_v, wb_st_addr, wb_st_size, wb_st_data),
                               rd_a_q, rd_sz_q, ex_st_v, ex_st_addr, ex_st_size, ex_st_data);

// the capture in this cycle, as the dispatch sees it
wire        cap      = rd_pend && rd_ack && !rd_drop;
wire [31:0] s_addr_c = (cap && rd_tag == T_SMI) ? rd_data + eac_i.src_add : s_addr_now;
wire [31:0] d_addr_c = (cap && rd_tag == T_DMI) ? rd_data + eac_i.dst_add : d_addr_now;
wire        dn_smi   = done_smi || (cap && rd_tag == T_SMI);
wire        dn_dmi   = done_dmi || (cap && rd_tag == T_DMI);
wire        dn_sld   = done_sld || (cap && rd_tag == T_SLD);
wire        dn_dld   = done_dld || (cap && rd_tag == T_DLD);
wire [31:0] s_val_c  = (cap && rd_tag == T_SLD) ? rd_data : s_val;
wire [31:0] d_val_c  = (cap && rd_tag == T_DLD) ? rd_data : d_val;
// Timing (plan M3 OOC, WNS -8.6 ns before this): instructions whose
// EA-fetch decision -- trap or not, one micro-op or two, the field address
// -- depends on operand VALUES do not take them straight from EX's result
// or from a load answering this clock; they wait one clock and use the
// register-file write-through / the captured load instead.  (The EX write
// ports themselves never depend on a result: ap040_execute.v.)
wire vdep = (i.cls == CL_CHK) || (i.cls == CL_CHK2) || (i.cls == CL_MULDIV && i.imm[0]) ||
            (i.cls == CL_BF) || (i.cls == CL_CAS2);
function automatic logic hz(input logic v, input logic [4:0] r, input logic [4:0] a, input logic [4:0] b,
                            input logic [4:0] c, input logic [4:0] d);
	return v && (r == a || r == b || r == c || r == d);
endfunction
wire ex_haz = hz(ex_w0_v, ex_w0_r, ra_a, ra_b, ra_c, ra_d) || hz(ex_u0_v, ex_u0_r, ra_a, ra_b, ra_c, ra_d) ||
              hz(ex_u1_v, ex_u1_r, ra_a, ra_b, ra_c, ra_d);
wire vhold = vdep && (cap || ex_haz);
wire ops_done = (!need_smi || dn_smi) && (!need_dmi || dn_dmi) &&
                (!needs_ld_src || dn_sld) && (!needs_ld_dst || dn_dld) && !vhold;

// odd control-flow targets (M68040UM 8.2.2; reference ap040_core.v S_JMP1/S_JSR1/S_RET2)
wire jmp_odd = (i.cls == CL_JMP || i.cls == CL_JSR) && s_addr_c[0];
wire rts_odd = (i.cls == CL_RTS || i.cls == CL_RTD) && s_val_c[0];
wire rtr_odd = (i.cls == CL_RTR) && d_val_c[0];
wire indexed_mode = (i.src.mode == 3'd6) || (i.src.mode == 3'd7 && i.src.mreg == 3'd3);

//--------------------------------------------------------------- micro-op build
function automatic ex_t base_uop(input id_t i);
	ex_t x;
	x = '0;
	x.pc = i.pc; x.next_pc = i.next_pc; x.opcode = i.opcode;
	x.cls = i.cls; x.alu = i.alu; x.size = i.size; x.cond = i.cond;
	x.dr = R_NONE; x.u0_r = R_NONE; x.u1_r = R_NONE; x.sp_r = R_NONE;
	x.btarget = i.btarget;
	x.last = 1'b1;
	return x;
endfunction

function automatic ex_t xord(input eac_t e, input logic [31:0] opa, input logic [31:0] opb,
                             input logic [31:0] opc,
                             input logic [31:0] sa, input logic [31:0] sv,
                             input logic [31:0] da, input logic [31:0] dv);
	ex_t x;
	id_t i;
	i = e.i;
	x = base_uop(i);
	x.wr_ccr   = i.wr_ccr;
	x.nowrite  = i.nowrite;
	x.ccr_only = i.ccr_only;
	x.ext      = i.ext;
	x.dr2      = i.reg_c;
	// the third operand: CAS Du / DIV.L Dr (register), CHK2's upper bound
	// (the second load), PACK/UNPK's adjustment
	x.c = (i.cls == CL_CHK2) ? dv : (i.cls == CL_PACK || i.cls == CL_UNPK) ? i.imm : opc;
	if (i.cls == CL_MULDIV) x.imm4 = i.imm[3:0];
	case (i.src.kind)
		EK_DREG, EK_AREG: x.a = opa;
		EK_IMM:           x.a = i.src.bd;
		EK_MEM:           x.a = (i.cls == CL_JMP || i.cls == CL_JSR || i.cls == CL_LEA || i.cls == CL_PEA) ? sa : sv;
		default:          x.a = 32'd0;
	endcase
	case (i.dst.kind)
		EK_DREG, EK_AREG: begin x.b = opb; x.dk = DK_REG; x.dr = e.dst_r; end
		EK_MEM:           begin x.b = dv;  x.dk = DK_MEM; x.daddr = da; end
		EK_IMM:           x.b = i.dst.bd;                // BTST Dn,#imm
		default: ;
	endcase
	x.u0_v = e.u0_v; x.u0_r = e.u0_r; x.u0_val = e.u0_val;
	x.u1_v = e.u1_v; x.u1_r = e.u1_r; x.u1_val = e.u1_val;
	// MOVES An,(An)+ / -(An): the 68040 stores the updated An (PRM 6-25 note)
	if (i.fcsel == 2'd2 && e.u1_v && e.u1_r == e.src_r) x.a = e.u1_val;
	case (i.cls)
		// JMP/JSR/RTS were redirected before EX (EA-calc, or this stage)
		CL_JMP, CL_JSR: begin x.target = sa; x.redirect = 1'b0; end
		CL_RTS, CL_RTD: begin x.target = sv; x.redirect = 1'b0; end
		CL_RTR:         begin x.target = dv; x.redirect = 1'b0; x.dk = DK_NONE; end
		CL_MOVE2SR, CL_SROP: begin x.target = i.next_pc; x.redirect = 1'b1; end
		// LINK A7: the value pushed is the decremented SP (PRM LINK: SP-4 -> SP;
		// An -> (SP)), i.e. the push address
		CL_LINK:        x.a = (e.src_r == e.dst_r) ? da : opa;
		// EXG: Rx <- Ry (w0), Ry <- Rx (u0: the value is known here)
		CL_CAS: x.dr = e.src_r;           // Dc, written when the compare fails
		CL_EXG: begin
			x.dk = DK_REG; x.dr = e.src_r;
			x.u0_v = 1'b1; x.u0_r = e.dst_r; x.u0_val = opa;
		end
		CL_MOVEC: begin
			x.creg_sel = i.imm[3:0];
			x.creg_to  = i.imm[4];
			x.a        = opa;
			x.dk       = DK_NONE;
			x.dr       = R_NONE;
			if (!i.imm[4]) begin                 // Rc -> Rn
				x.dk = DK_REG; x.dr = e.src_r;
			end else if (i.imm[3:0] == CR_USP || i.imm[3:0] == CR_ISP || i.imm[3:0] == CR_MSP) begin
				x.dk = DK_REG;
				x.dr = (i.imm[3:0] == CR_USP) ? R_USP : (i.imm[3:0] == CR_ISP) ? R_ISP : R_MSP;
			end
		end
		default: ;
	endcase
	return x;
endfunction

wire ex_t x_ord1 = xord(eac_i, op_a, op_b, op_c, s_addr_c, s_val_c, d_addr_c, d_val_c);

// Bitfield evaluation on a 64-bit window: {Dn, Dn} for a register field
// (offset mod 32; a field past bit 0 wraps to bit 31), or the memory bytes
// {long, byte 5, 24'b0} (offset mod 8).  Flags per PRM BFxxx: N = the
// field's (BFINS: the inserted value's) most significant bit, Z = all zero,
// V = C = 0, X kept.  BFFFO: offset + the first set bit, or offset + width.
function automatic logic [5:0] clz32(input logic [31:0] v);
	logic [5:0] n;
	int k;
	n = 6'd32;
	for (k = 0; k < 32; k = k + 1)
		if (v[k]) n = 6'd31 - k[5:0];
	return n;
endfunction

typedef struct packed {
	logic [1:0]  nz;       // N, Z
	logic [31:0] val;      // BFEXTU/BFEXTS/BFFFO result, or the new field register
	logic [63:0] nw;       // the window with the new field in it (memory form)
} bfres_t;

function automatic bfres_t bf_eval(input logic [2:0] op, input logic [63:0] win, input logic [5:0] o,
                                   input logic [5:0] w, input logic [31:0] du, input logic [31:0] off,
                                   input logic regf);
	bfres_t r;
	logic [63:0] sh, m64, n64;
	logic [31:0] fl, maskl, ones, field, nf, al;
	sh    = win << o;
	fl    = sh[63:32];                                   // field left aligned
	maskl = (w == 6'd32) ? 32'hFFFF_FFFF : ~(32'hFFFF_FFFF >> w);
	ones  = (w == 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << w) - 32'd1);
	field = (w == 6'd32) ? fl : (fl >> (6'd32 - w));
	case (op)
		3'd2:    nf = (~field) & ones;                   // BFCHG
		3'd4:    nf = 32'd0;                             // BFCLR
		3'd6:    nf = ones;                              // BFSET
		default: nf = du & ones;                         // BFINS
	endcase
	r.nz[1] = (op == 3'd7) ? nf[w - 6'd1] : field[w - 6'd1];
	r.nz[0] = (op == 3'd7) ? (nf == 32'd0) : (field == 32'd0);
	al = fl & maskl;
	m64 = {maskl, 32'd0} >> o;
	n64 = {((w == 6'd32) ? nf : (nf << (6'd32 - w))), 32'd0} >> o;
	r.nw = (win & ~m64) | (n64 & m64);
	case (op)
		3'd1:    r.val = field;
		3'd3:    r.val = field | (field[w - 6'd1] ? ~ones : 32'd0);
		3'd5:    r.val = off + {26'd0, (al == 32'd0) ? w : clz32(al)};
		default: r.val = (win[63:32] & ~(m64[63:32] | m64[31:0])) |
		                 (n64[63:32] & m64[63:32]) | (n64[31:0] & m64[31:0]);   // register field
	endcase
	return r;
endfunction

wire bfres_t bfr = bf_eval(i.alu[2:0],
                           bf_mem ? {d_val, s_val[7:0], 24'd0} : {op_b, op_b},   // (vhold: loads captured)
                           bf_mem ? {3'd0, bf_off[2:0]} : {1'b0, bf_off[4:0]},
                           bf_w, op_a, bf_off, !bf_mem);

// the bitfield micro-ops: 0 flags + register result + first store,
// 1 the trailing byte store of a 3- or 5-byte field
function automatic ex_t bf_uop(input ex_t x0, input logic sec, input eac_t e, input bfres_t r,
                               input logic mem, input logic modify, input logic two,
                               input logic [2:0] n, input logic [31:0] a);
	ex_t x;
	logic [2:0] op;
	op = e.i.alu[2:0];
	x = x0;
	x.a = {28'd0, r.nz, 2'b00};
	x.c = r.val;
	x.dk = DK_NONE; x.dr = R_NONE;
	x.st_v = 1'b0;
	if (op == 3'd1 || op == 3'd3 || op == 3'd5) begin x.dk = DK_REG; x.dr = e.src_r; end
	else if (!mem && modify)                    begin x.dk = DK_REG; x.dr = e.dst_r; end
	if (mem && modify) begin
		x.st_v = 1'b1; x.st_addr = a;
		case (n)
			3'd1:       begin x.st_size = SZ_B; x.st_data = {24'd0, r.nw[63:56]}; end
			3'd2, 3'd3: begin x.st_size = SZ_W; x.st_data = {16'd0, r.nw[63:48]}; end
			default:    begin x.st_size = SZ_L; x.st_data = r.nw[63:32]; end
		endcase
	end
	x.last = !two;
	if (sec) begin
		x.wr_ccr = 1'b0; x.dk = DK_NONE; x.dr = R_NONE;
		x.u0_v = 1'b0; x.u1_v = 1'b0;
		x.st_size = SZ_B;
		x.st_addr = a + ((n == 3'd3) ? 32'd2 : 32'd4);
		x.st_data = {24'd0, (n == 3'd3) ? r.nw[47:40] : r.nw[31:24]};
		x.last = 1'b1;
	end
	return x;
endfunction

// CAS2 (PRM 4-66..4-68): compare (Rn1) with Dc1, then (Rn2) with Dc2; both
// equal: Du1 -> (Rn1), Du2 -> (Rn2) (two micro-ops); else (Rn1) -> Dc1 (w0)
// and (Rn2) -> Dc2 (u1; w0 wins when Dc1 = Dc2: "memory operand 1 is
// stored", PRM 4-68 -- see PLAN D7), and the M68040 ends the locked
// sequence with a write of the second operand read (M68040UM 7.4.5 p. 7-26).
// EX's CMP makes the flags from x.b - x.a.
function automatic logic [31:0] mrg(input logic [31:0] old, input logic [31:0] v, input logic [1:0] sz);
	return (sz == SZ_W) ? {old[31:16], v[15:0]} : v;
endfunction

function automatic ex_t cas2_uop(input ex_t x0, input logic sec, input eac_t e,
                                 input logic [31:0] dc1, input logic [31:0] dc2,
                                 input logic [31:0] du1, input logic [31:0] du2,
                                 input logic [31:0] a1, input logic [31:0] m1,
                                 input logic [31:0] a2, input logic [31:0] m2);
	ex_t x;
	logic [1:0] sz;
	logic eq1, eq2;
	sz  = e.i.size;
	eq1 = (sz == SZ_W) ? (m1[15:0] == dc1[15:0]) : (m1 == dc1);
	eq2 = (sz == SZ_W) ? (m2[15:0] == dc2[15:0]) : (m2 == dc2);
	x = x0;
	x.a = eq1 ? dc2 : dc1;
	x.b = eq1 ? m2 : m1;
	x.dk = DK_NONE; x.dr = R_NONE;
	x.u0_v = 1'b0; x.u1_v = 1'b0;
	x.st_v = 1'b1; x.st_size = sz; x.st_rb = 1'b0;
	x.last = 1'b1;
	if (eq1 && eq2) begin
		x.st_addr = sec ? a2 : a1;
		x.st_data = (sec ? du2 : du1) & szmask(sz);
		x.last = sec;
		if (sec) x.wr_ccr = 1'b0;
	end else begin
		x.dk = DK_REG; x.dr = {2'b00, e.i.ext[2:0]}; x.c = mrg(dc1, m1, sz);
		x.u1_v = 1'b1; x.u1_r = {2'b00, e.i.ext2[2:0]}; x.u1_val = mrg(dc2, m2, sz);
		x.st_addr = a2; x.st_data = m2 & szmask(sz); x.st_rb = 1'b1;
	end
	return x;
endfunction

// decided from the register file and the captured loads (vhold: no EX
// hazard, no load answering this clock), off EX's result path
wire cas2_two = (i.cls == CL_CAS2) &&
                ((i.size == SZ_W) ? (s_val[15:0] == rd_a[15:0]) : (s_val == rd_a)) &&
                ((i.size == SZ_W) ? (d_val[15:0] == rd_b[15:0]) : (d_val == rd_b));

reg bf_step;               // the second micro-op (bitfield trailing byte, CAS2 Du2) is next
wire ex_t x_ord0 = is_bf ? bf_uop(x_ord1, bf_step, eac_i, bfr, bf_mem, bf_modify, bf_two, bf_n, bf_addr) :
                   (i.cls == CL_CAS2) ? cas2_uop(x_ord1, bf_step, eac_i, op_a, op_b, op_c, op_d,
                                                 s_addr_c, s_val, d_addr_c, d_val) :   // (vhold: loads captured)
                   x_ord1;
wire two_uop = bf_two || cas2_two;
function automatic ex_t with_cc(input ex_t x, input logic c);
	ex_t y;
	y = x; y.cc = c;
	return y;
endfunction
wire [4:0] ex_ccr_here = ex_ccr_v ? ex_ccr : sr_in[4:0];
wire       br_cc       = cond_true(i.cond, ex_ccr_here);

// M3 traps, decided here where every operand is in hand (M68040UM 8.2.3
// p. 8-8: format $2, stacked PC = the next instruction, address field = the
// trapping one).  An (An)+/-(An) update of the trapping instruction stands.
function automatic logic signed [31:0] sized_s(input logic [31:0] v, input logic [1:0] sz);
	return (sz == SZ_B) ? $signed(sext8(v[7:0])) : (sz == SZ_W) ? $signed(sext16(v[15:0])) : $signed(v);
endfunction
// The trap decisions use the register file and the captured loads, never
// EX's result or a load answering this clock (vhold guarantees they are
// the same values when the decision is taken): timing, plan M3.
function automatic logic [31:0] dsrc(input id_t i, input logic [31:0] ra, input logic [31:0] sv);
	case (i.src.kind)
		EK_DREG, EK_AREG: return ra;
		EK_IMM:           return i.src.bd;
		default:          return sv;
	endcase
endfunction
wire [31:0] dec_src = dsrc(i, rd_a, s_val);
wire signed [31:0] chk_v  = sized_s(rd_b, i.size);
wire signed [31:0] chk_b  = sized_s(dec_src, i.size);
wire signed [31:0] c2_rn  = (i.dst.kind == EK_AREG) ? $signed(rd_b) : sized_s(rd_b, i.size);
wire signed [31:0] c2_lb  = sized_s(s_val, i.size);
wire signed [31:0] c2_ub  = sized_s(d_val, i.size);
wire c2_oob   = (c2_lb <= c2_ub) ? (c2_rn < c2_lb || c2_rn > c2_ub) : (c2_rn < c2_lb && c2_rn > c2_ub);
wire divz     = (i.cls == CL_MULDIV) && i.imm[0] &&
                ((i.size == SZ_W) ? (dec_src[15:0] == 16'd0) : (dec_src == 32'd0));
wire trap_u   = (i.cls == CL_CHK && (chk_v < 0 || chk_v > chk_b)) ||   // CHK: vector 6
                (i.cls == CL_CHK2 && i.ext[11] && c2_oob) ||            // CHK2: vector 6
                divz;                                                   // DIVx by zero: vector 5
wire trap_n   = (i.cls == CL_TRAPCC) && br_cc;                        // TRAPcc/TRAPV: vector 7
wire [7:0] trap_vec = divz ? 8'd5 : trap_n ? 8'd7 : 8'd6;

// MUL/DIV carry "divide by zero" in cc (EX then only clears C, 68040
// DIVU/DIVS by zero: X N Z V kept, reference S_MDL_RDQ)
// CAS: the compare's equality is decided here, so EX's store data and Dc
// value are selected by a register, not by its own compare (timing)
wire       cas_eq = (i.size == SZ_B) ? (x_ord0.a[7:0] == x_ord0.b[7:0]) :
                    (i.size == SZ_W) ? (x_ord0.a[15:0] == x_ord0.b[15:0]) : (x_ord0.a == x_ord0.b);
wire ex_t  x_ord       = with_cc(x_ord0, (i.cls == CL_MULDIV) ? divz : (i.cls == CL_CAS) ? cas_eq : br_cc);

function automatic logic [31:0] fsize(input logic [3:0] f);
	case (f)
		4'd2, 4'd3: return 32'd12;
		4'd4:       return 32'd16;
		4'd7:       return 32'd60;
		default:    return 32'd8;
	endcase
endfunction

// one exception-frame store
function automatic ex_t exc_uop(input id_t i, input logic [2:0] st, input logic [31:0] sp,
                                input logic [15:0] sr, input logic [31:0] pc, input logic [3:0] fmt,
                                input logic [7:0] vec, input logic [31:0] addr);
	ex_t x;
	x = base_uop(i);
	x.cls  = CL_EXC;
	x.last = 1'b0;
	x.st_v = 1'b1; x.st_size = SZ_L;
	case (st)
		3'd0:    begin x.st_addr = sp;         x.st_data = {sr, pc[31:16]}; end
		3'd1:    begin x.st_addr = sp + 32'd4; x.st_data = {pc[15:0], fmt, 2'b00, vec, 2'b00}; end
		default: begin x.st_addr = sp + 32'd8; x.st_data = addr; end
	endcase
	return x;
endfunction

// the exception-entry final micro-op
function automatic ex_t exc_final(input id_t i, input logic [4:0] bank, input logic [31:0] sp,
                                  input logic [15:0] sr, input logic [31:0] target);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_EXC;
	x.exc = 1'b1;
	x.sp_v = 1'b1; x.sp_r = bank; x.sp_val = sp;
	// S set, T1/T0 cleared, M kept (M68040UM 8.1, p. 8-4)
	x.sr_v = 1'b1; x.sr_val = {2'b00, 1'b1, sr[12:0]} & `AP040_SR_MASK;
	x.target = target;
	x.redirect = !target[0];
	x.last = !target[0];
	return x;
endfunction

// the RTE final micro-op
function automatic ex_t rte_final(input id_t i, input logic [4:0] bank, input logic [31:0] sp,
                                  input logic [15:0] fv, input logic [15:0] sr, input logic [31:0] pc);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_RTE;
	x.sp_v = 1'b1; x.sp_r = bank; x.sp_val = sp + fsize(fv[15:12]);
	x.sr_v = 1'b1; x.sr_val = sr & `AP040_SR_MASK;
	x.target = pc;
	x.redirect = (fv[15:12] != 4'd1) && !pc[0];
	x.last = x.redirect;
	return x;
endfunction

function automatic ex_t reset_final(input id_t i, input logic [31:0] ssp, input logic [31:0] pc);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_RESET;
	x.pc = 32'hFFFF_FFFF;
	x.sp_v = 1'b1; x.sp_r = R_ISP; x.sp_val = ssp;
	x.target = pc; x.redirect = 1'b1;
	return x;
endfunction

wire rte_fmt_ok = (r_fv[15:12] <= 4'd4) || (r_fv[15:12] == 4'd7);
wire rte_goes   = (r_fv[15:12] != 4'd1) && !r_pc[0];   // the RTE final micro-op redirects

//--------------------------------------------------------------- the step logic
typedef struct packed {
	logic        issue;  logic [2:0] it; logic [31:0] ia; logic [1:0] isz;
	logic        disp;   // a micro-op goes to EX this cycle
	logic        fin;    // the current instruction leaves EA-fetch this cycle
	logic [2:0]  dsel;   // which micro-op: 0 ordinary, 1 frame store, 2 exc final, 3 rte final, 4 reset
	logic        exc_go; logic [7:0] ev; logic [3:0] ef; logic [31:0] epc; logic [31:0] eaddr;
	logic        mm_go;  // MOVEM: the EA is known (memory-indirect pointer fetched), start the transfers
} stp_t;

function automatic stp_t stepf(
	input logic [3:0] ph, input logic ev_valid, input logic rstp, input id_t i,
	input logic older_busy, input logic can_rd, input logic rd_pend, input logic rd_ack, input logic cap,
	input logic s_bit, input logic stall,
	input rdreq_t nx, input logic ops_done, input logic jmp_odd, input logic rts_odd, input logic rtr_odd,
	input logic trap_u, input logic trap_n, input logic [7:0] trap_vec,
	input logic indexed, input logic two, input logic tstep,
	input logic [31:0] s_addr_c, input logic [31:0] s_val_c, input logic [31:0] d_val_c,
	input logic [2:0] x_step, input logic [31:0] vbr, input logic [7:0] x_vec, input logic [31:0] x_target,
	input logic [2:0] r_step, input logic [31:0] sp_now, input logic fmt_ok, input logic rte_goes);
	stp_t s;
	s = '0;
	case (ph)
		P_START, P_OPS: if (ev_valid && !rstp) begin
			if (i.serialize && older_busy && ph == P_START) begin
				// wait until everything older has committed
			end else if (i.priv && !s_bit) begin
				s.exc_go = 1'b1; s.ev = 8'd8; s.ef = 4'd0; s.epc = i.pc;
			end else if (i.cls == CL_EXC) begin
				s.exc_go = 1'b1; s.ev = i.exc_vec; s.ef = i.exc_fmt;
				s.epc = i.exc_next ? i.next_pc : i.pc; s.eaddr = i.exc_addr;
			end else if (i.cls == CL_RTE) begin
				// the sequence runs in P_RTE
			end else begin
				if (nx.v && !cap && can_rd && !rd_pend) begin
					s.issue = 1'b1; s.it = nx.t; s.ia = nx.a; s.isz = nx.sz;
				end
				if (ops_done && !(rd_pend && !rd_ack)) begin
					if (jmp_odd) begin
						// JMP: the frame PC is where gencpu's PC had reached (reference S_JMP1);
						// JSR: the fault is on the fetch at the target, no push (S_JSR1)
						s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
						s.epc = (i.cls == CL_JSR) ? s_addr_c : (i.pc + (indexed ? 32'd6 : 32'd2));
						s.eaddr = {s_addr_c[31:1], 1'b0};
					end else if (rts_odd) begin
						// the pop is backed out (reference S_RET2): no micro-op, SP untouched
						s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
						s.epc = i.pc; s.eaddr = {s_val_c[31:1], 1'b0};
					end else if (trap_u) begin
						// CHK/CHK2/DIV by zero: the micro-op (flags; An updates stand)
						// commits, then the trap is taken with that SR
						if (!stall) begin
							s.disp = 1'b1; s.dsel = 3'd6;
							s.exc_go = 1'b1; s.ev = trap_vec; s.ef = 4'd2;
							s.epc = i.next_pc; s.eaddr = i.pc;
						end
					end else if (trap_n) begin
						s.exc_go = 1'b1; s.ev = trap_vec; s.ef = 4'd2;
						s.epc = i.next_pc; s.eaddr = i.pc;
					end else if (rtr_odd) begin
						// RTR to an odd PC: the popped CCR stands, SP does not move, and
						// the frame stacks the SR with that CCR (reference S_RET3)
						if (!stall) begin
							s.disp = 1'b1; s.dsel = 3'd5;
							s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
							s.epc = i.pc; s.eaddr = {d_val_c[31:1], 1'b0};
						end
					end else if (i.cls == CL_MOVEM) begin
						s.mm_go = 1'b1;
					end else if (!stall) begin
						// a two-micro-op instruction (bitfield trailing byte) finishes on the second
						s.disp = 1'b1; s.dsel = 3'd0; s.fin = !two || tstep;
					end
				end
			end
		end
		P_EXC: begin
			if (x_step <= 3'd2) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd1; end
			end else if (x_step == 3'd3) begin
				if (!rd_pend && can_rd) begin
					s.issue = 1'b1; s.it = T_VEC; s.ia = vbr + {22'd0, x_vec, 2'b00}; s.isz = SZ_L;
				end
			end else if (x_step == 3'd4) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd2; s.fin = !x_target[0]; end
			end
		end
		P_RTE: begin
			if (r_step <= 3'd2) begin
				if (!rd_pend && can_rd) begin
					s.issue = 1'b1; s.it = T_SEQ0 + r_step;
					s.ia = sp_now + ((r_step == 3'd0) ? 32'd0 : (r_step == 3'd1) ? 32'd2 : 32'd6);
					s.isz = (r_step == 3'd1) ? SZ_L : SZ_W;
				end
			end else if (r_step == 3'd3) begin
				if (fmt_ok) begin
					if (!stall) begin s.disp = 1'b1; s.dsel = 3'd3; s.fin = rte_goes; end
				end else begin
					// format error: vector 14, format $0, PC = the RTE
					s.exc_go = 1'b1; s.ev = 8'd14; s.ef = 4'd0; s.epc = i.pc;
				end
			end
		end
		P_RESET: begin
			if (r_step <= 3'd1) begin
				if (!rd_pend) begin
					s.issue = 1'b1; s.it = T_SEQ0 + r_step; s.ia = (r_step == 3'd0) ? 32'd0 : 32'd4; s.isz = SZ_L;
				end
			end else if (r_step == 3'd2) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd4; end
			end
		end
		default: ;
	endcase
	return s;
endfunction

// reads never wait for older stores (store-to-load forwarding, above)
// a bitfield's read address uses the register file: no read while EX writes one of its registers
wire bf_rdblk = is_bf && ex_haz;
wire stp_t st0 = stepf(ph, eac_valid, rst_pending, i, older_busy, !bf_rdblk, rd_pend, rd_ack, cap,
                      s_bit, stall_in, nx, ops_done, jmp_odd, rts_odd, rtr_odd, trap_u, trap_n, trap_vec,
                      indexed_mode, two_uop, bf_step, s_addr_c, s_val_c,
                      d_val_c, x_step, vbr_in, x_vec, x_target, r_step, rd_a, rte_fmt_ok, rte_goes);

//--------------------------------------------------------------- MOVEM
// PRM 4-128..4-131.  Mask bit k names D0..D7, A0..A7 (k = 0..15), reversed
// for -(An).  One micro-op per register: a store (the register read through
// port c, EX-forwarded), or a load's register write (word loads sign-extend
// into Dn as well).  Memory to
// registers with (An)+: the base register is not loaded, it gets the
// incremented address.  (-(An): the base register's stored value is its
// initial value minus the size, PRM 4-128.)  The An update rides on the
// last micro-op.  Loads
// go one per clock: the next read issues in the clock a read answers; a
// load answering while EX stalls waits in mm_have.  mm_mask and mm_addr
// are the saved state M6's restart will use (plan M4 Files).
reg  [15:0] mm_mask;       // registers still to transfer (loads: still to read)
reg  [31:0] mm_addr;       // next address
reg         mm_empty;      // the mask was zero: one empty micro-op retires it
reg   [4:0] mm_rreg;       // the outstanding read's register
reg         mm_rlast;      // ... and it is the last one
reg         mm_have;       // a loaded value waiting for EX
reg  [31:0] mm_hdata;
reg   [4:0] mm_hreg;
reg         mm_hlast;

wire        mm_ld   = i.imm[0];
// MOVEP (PRM 4-133): the same sequencer on bytes at every other address;
// stores send the register's bytes high first, loads collect the bytes and
// write Dx once (the low word for .W) with the last one
wire        mm_p    = i.imm[1];
wire  [4:0] mp_reg  = mm_ld ? eac_i.dst_r : eac_i.src_r;
// MOVE16 (PRM 4-125): the four source longwords are read into m16_buf
// (one per clock) and each is stored to the destination line as soon as it
// is in (the lines are aligned to 16, so they are the same line or
// disjoint: a store never changes a longword still to be read); a
// postincremented register gets +16 once (the same register named twice:
// once -- WinUAE gencpu i_MOVE16, PRM silent).  The line is moved in
// address order (the burst's start-at-EA order is a bus detail the M5
// adapter can add).
wire        mm_16   = i.imm[2];
reg   [3:0] m16_smask;     // longwords still to store
reg   [3:0] m16_have;      // longwords read
reg  [31:0] m16_saddr;     // next store address
reg  [31:0] m16_buf [0:3];
reg   [1:0] mm_rk;         // the outstanding read's index (MOVE16)
wire        mm_lde  = mm_16 ? 1'b1 : mm_ld;        // MOVE16's reads run through the load path
wire  [1:0] m16_ks  = m16_smask[0] ? 2'd0 : m16_smask[1] ? 2'd1 : m16_smask[2] ? 2'd2 : 2'd3;
wire        m16_sd  = mm_16 && (m16_smask != 4'd0) && m16_have[m16_ks] && !stall_in;
wire        m16_sf  = m16_sd && ((m16_smask & (m16_smask - 4'd1)) == 4'd0);
wire        mm_pre  = (i.dst.kind == EK_MEM) && (i.dst.mode == 3'd4);
wire        mm_post = (i.src.kind == EK_MEM) && (i.src.mode == 3'd3);
wire  [4:0] mm_base = mm_ld ? eac_i.src_r : eac_i.dst_r;
wire [31:0] mm_sz   = (mm_p || i.size == SZ_W) ? 32'd2 : 32'd4;

function automatic logic [3:0] lsb16(input logic [15:0] m);
	logic [3:0] k;
	int j;
	k = 4'd0;
	for (j = 15; j >= 0; j = j - 1)
		if (m[j]) k = j[3:0];
	return k;
endfunction
function automatic logic [4:0] mm_reg(input logic [3:0] k, input logic pre, input logic s, input logic m);
	logic [3:0] j;
	j = pre ? 4'd15 - k : k;
	return (j == 4'd15) ? resolve_sp(R_A7L, s, m) : {1'b0, j};   // 0-7 D0-D7, 8-14 A0-A6
endfunction
wire  [3:0] mm_k     = lsb16(mm_mask);
wire  [4:0] mm_sreg  = mm_p ? mp_reg : mm_reg(mm_k, mm_pre, s_bit, sr_in[12]);
reg  [23:0] mp_acc;        // MOVEP load: the bytes so far
wire        mm_one   = (mm_mask & (mm_mask - 16'd1)) == 16'd0;   // at most one register left

// the step: loads issue from mm_mask and dispatch from the answer (or
// mm_have); stores dispatch from mm_mask
typedef struct packed {
	logic issue; logic disp; logic fin; logic from_buf; logic to_buf; logic empty;
} mms_t;
function automatic mms_t mm_step(input logic ld, input logic [15:0] mask, input logic empty,
                                 input logic pend, input logic cap, input logic have, input logic stall,
                                 input logic rlast, input logic hlast, input logic one, input logic mp,
                                 input logic nodisp);
	mms_t r;
	r = '0;
	if (empty) begin
		if (!stall) begin r.disp = 1'b1; r.fin = 1'b1; r.empty = 1'b1; end
	end else if (ld) begin
		if (have) begin
			if (!stall) begin r.disp = 1'b1; r.from_buf = 1'b1; r.fin = hlast; end
		end else if (cap && (!mp || rlast) && !nodisp) begin   // (MOVEP: only the last byte; MOVE16: none)
			if (!stall) begin r.disp = 1'b1; r.fin = rlast; end
			else r.to_buf = 1'b1;
		end
		r.issue = (mask != 16'd0) && (!pend || cap) && !have && !stall;
	end else begin
		if (!stall && mask != 16'd0) begin r.disp = 1'b1; r.fin = one; end
	end
	return r;
endfunction
wire mms_t mms = mm_step(mm_lde, mm_mask, mm_empty, rd_pend, cap, mm_have, stall_in, mm_rlast, mm_hlast, mm_one,
                         mm_p, mm_16);

function automatic ex_t mm_uop(input id_t i, input mms_t m, input logic ld, input logic [4:0] r,
                               input logic [31:0] v, input logic [31:0] addr, input logic last,
                               input logic upd, input logic [4:0] br, input logic [31:0] bval,
                               input logic skipw, input logic mp, input logic [3:0] k);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_MOVEM;
	x.last = last;
	if (m.empty) ;
	else if (ld) begin
		if (!skipw) begin
			x.dk = DK_REG; x.dr = r;
			x.c = mp ? v : (i.size == SZ_W) ? sext16(v[15:0]) : v;   // (MOVEP: v is the merged Dx)
		end
	end else if (mp) begin                        // byte k, high first
		x.st_v = 1'b1; x.st_addr = addr; x.st_size = SZ_B;
		x.st_data = {24'd0, (i.size == SZ_W) ? v[8 * (1 - k[0]) +: 8] : v[8 * (3 - k[1:0]) +: 8]};
	end else begin
		x.st_v = 1'b1; x.st_addr = addr; x.st_size = i.size;
		x.st_data = (i.size == SZ_W) ? {16'd0, v[15:0]} : v;
	end
	if (last && upd && !m.empty) begin x.u1_v = 1'b1; x.u1_r = br; x.u1_val = bval; end
	return x;
endfunction
wire  [4:0] mm_dreg = mm_lde ? (mms.from_buf ? mm_hreg : mm_rreg) : mm_sreg;
// -(An) with the base in the list: the MC68020/30/40 store the initial
// value decremented by the operand size (PRM 4-128; plan D8)
// MOVEP load: the last byte completes Dx (.W: its low word; op_b = Dx)
wire [31:0] mp_val  = (i.size == SZ_W) ? {op_b[31:16], mp_acc[7:0], rd_data[7:0]} : {mp_acc, rd_data[7:0]};
wire [31:0] mm_dval = mm_ld ? (mms.from_buf ? mm_hdata : mm_p ? mp_val : rd_data) :
                      (mm_pre && mm_sreg == mm_base) ? op_c - mm_sz : op_c;
function automatic ex_t m16_upd(input ex_t x0, input logic m16, input logic last, input eac_t e);
	ex_t x;
	x = x0;
	if (m16 && last) begin
		x.u0_v = e.i.imm[3]; x.u0_r = e.src_r; x.u0_val = e.src_ea + 32'd16;
		x.u1_v = e.i.imm[4]; x.u1_r = e.dst_r;
		x.u1_val = ((e.src_r == e.dst_r) ? e.src_ea : e.dst_ea) + 32'd16;
	end
	return x;
endfunction
wire ex_t   mm_x0   = mm_uop(i, mms, mm_lde, mm_dreg, mm_dval, mm_addr, mms.fin, mm_pre || mm_post,
                             mm_base, mm_addr, mm_post && mm_dreg == mm_base, mm_p, mm_k);
wire ex_t   m16_x   = m16_upd(mm_uop(i, '0, 1'b0, 5'd0, m16_buf[m16_ks], m16_saddr, m16_sf, 1'b0,
                                     5'd0, 32'd0, 1'b0, 1'b0, 4'd0),
                              1'b1, m16_sf, eac_i);
wire ex_t   mm_x    = mm_16 ? m16_x : mm_x0;

function automatic stp_t mm_st(input mms_t m, input logic [31:0] a, input logic [1:0] sz);
	stp_t t;
	t = '0;
	t.issue = m.issue; t.it = T_SLD; t.ia = a; t.isz = sz;
	t.disp = m.disp; t.dsel = 3'd7; t.fin = m.fin;
	return t;
endfunction
function automatic stp_t m16_st_f(input stp_t t0, input logic sd, input logic sf);
	stp_t t;
	t = t0; t.disp = sd; t.fin = sf;
	return t;
endfunction
wire stp_t st = (ph != P_MOVEM) ? st0 :
                mm_16 ? m16_st_f(mm_st(mms, mm_addr, i.size), m16_sd, m16_sf) :
                mm_st(mms, mm_addr, mm_p ? SZ_B : i.size);

// RTR to an odd PC: the CCR alone commits
function automatic ex_t ccr_only_uop(input ex_t x);
	ex_t y;
	y = x; y.u0_v = 1'b0; y.u1_v = 1'b0; y.redirect = 1'b0; y.last = 1'b0;
	return y;
endfunction

// a trapping CHK/CHK2/DIV: the micro-op commits, the exception follows
function automatic ex_t no_last(input ex_t x);
	ex_t y;
	y = x; y.redirect = 1'b0; y.last = 1'b0;
	return y;
endfunction

function automatic ex_t dmux(input logic [2:0] sel, input ex_t o, input ex_t f, input ex_t e,
                             input ex_t r, input ex_t z, input ex_t c, input ex_t n, input ex_t m);
	case (sel)
		3'd7: return m;
		3'd0: return o;
		3'd1: return f;
		3'd2: return e;
		3'd3: return r;
		3'd5: return c;
		3'd6: return n;
		default: return z;
	endcase
endfunction

wire ex_t disp_x0 = dmux(st.dsel, x_ord,
                        exc_uop(i, x_step, x_sp, x_sr, x_pc, x_fmt, x_vec, x_addr),
                        exc_final(i, x_bank, x_sp, x_sr, x_target),
                        rte_final(i, bank_now, rd_a, r_fv, r_sr, r_pc),
                        reset_final(i, x_sp, r_pc),
                        ccr_only_uop(x_ord),
                        no_last(x_ord),
                        mm_x);
// every store's function code: the frame stores and ordinary stores are
// data in the current mode (the frame: supervisor), MOVES: DFC
function automatic ex_t with_fc(input ex_t x, input logic [2:0] fc);
	ex_t y;
	y = x; y.st_fc = fc;
	return y;
endfunction
wire ex_t disp_x = with_fc(disp_x0, (st.dsel == 3'd1) ? 3'd5 : (st.dsel == 3'd0 && i.fcsel == 2'd2) ? dfc_in : fc_data);

// the early read goes out when this stage leaves the port free and is
// taking the next instruction (its current one finishes, or it is empty)
// function codes: supervisor/user data (5/1), MOVES: SFC for its read
// (plan M4; the lifted MMU's c_fc in M7)
wire [2:0] fc_data = s_bit ? 3'd5 : 3'd1;
// (exception entry's vector read and RTE's pops: supervisor data)
assign rd_fc     = (st.issue && (ph == P_START || ph == P_OPS) && i.fcsel == 2'd1) ? sfc_in :
                   (ph == P_EXC || ph == P_RTE || ph == P_RESET) ? 3'd5 : fc_data;
wire   use_early = early_v && early.v && !st.issue && (!rd_pend || rd_ack) &&
                   (st.fin || !eac_valid) && !rst_pending;
assign rd_req    = (st.issue || use_early) && !flush;
assign rd_addr   = st.issue ? st.ia  : early.a;
assign rd_size   = st.issue ? st.isz : early.sz;
wire [2:0] rd_t  = st.issue ? st.it  : early.t;
assign eaf_stall = eac_valid && !st.fin;
// (MOVEM blocks EA-calc for its whole stay: its register writes are not in eac_t)
assign eaf_blk   = eac_valid && (i.serialize || (ph != P_START && ph != P_OPS) || i.cls == CL_MOVEM);
assign halted    = (ph == P_HALT);

// Bcc/DBcc were guessed taken by ID; a not-taken one is corrected here,
// with the CCR the instruction ahead of it (in EX, or committing in WB)
// leaves -- a two-clock correction instead of the four a redirect from EX
// costs (M68040UM 10.5 p. 10-11: Bcc not taken 3, DBcc 3/4).
wire [15:0] dbc_dec = op_b[15:0] - 16'd1;
wire       br_taken = (i.cls == CL_BCC) ? br_cc : (!br_cc && dbc_dec != 16'hFFFF);

assign eaf_redir_v  = st.disp && st.dsel == 3'd0 && !flush &&
                      (i.cls == CL_RTS || i.cls == CL_RTD || i.cls == CL_RTR ||
                       ((i.cls == CL_JMP || i.cls == CL_JSR) && !eac_i.redirected) ||
                       ((i.cls == CL_BCC || i.cls == CL_DBCC) && !br_taken));
assign eaf_redir_pc = (i.cls == CL_RTS || i.cls == CL_RTD) ? s_val_c :
                      (i.cls == CL_RTR) ? d_val_c :
                      (i.cls == CL_BCC || i.cls == CL_DBCC) ? i.next_pc : s_addr_c;

//--------------------------------------------------------------- registers
always @(posedge clk) begin
	if (!nreset) begin
		ph <= P_START; rd_pend <= 1'b0; rd_tag <= 3'd0; rd_drop <= 1'b0;
		done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
		s_addr <= 32'd0; d_addr <= 32'd0; s_val <= 32'd0; d_val <= 32'd0;
		x_vec <= 8'd0; x_fmt <= 4'd0; x_pc <= 32'd0; x_addr <= 32'd0; x_step <= 3'd0;
		x_sr <= 16'd0; x_sp <= 32'd0; x_bank <= R_ISP; x_target <= 32'd0;
		bf_step <= 1'b0;
		mm_mask <= 16'd0; mm_addr <= 32'd0; mm_empty <= 1'b0; mm_rreg <= 5'd0; mm_rlast <= 1'b0;
		mm_have <= 1'b0; mm_hdata <= 32'd0; mm_hreg <= 5'd0; mm_hlast <= 1'b0;
		r_step <= 3'd0; r_sr <= 16'd0; r_pc <= 32'd0; r_fv <= 16'd0;
		rst_pending <= reset_seq;
		eaf_valid <= 1'b0; eaf_o <= '0;
	end else if (ce) begin
		// the EX-side output register
		if (flush) eaf_valid <= 1'b0;
		else if (!stall_in) begin
			eaf_valid <= st.disp;
			if (st.disp) eaf_o <= disp_x;
		end
		// read bookkeeping.  A read still outstanding when a flush arrives
		// is answered later; rd_drop throws that answer away.
		if (rd_req) begin rd_pend <= 1'b1; rd_tag <= rd_t; rd_a_q <= rd_addr; rd_sz_q <= rd_size; end
		else if (rd_ack) begin rd_pend <= 1'b0; rd_drop <= 1'b0; end
		if (flush) begin
			ph <= P_START; bf_step <= 1'b0; mm_have <= 1'b0; mm_empty <= 1'b0;
			done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
			if (rd_pend && !rd_ack) rd_drop <= 1'b1;
		end else begin
			if (cap) begin
				case (rd_tag)
					T_SMI: begin s_addr <= rd_data + eac_i.src_add; done_smi <= 1'b1; end
					T_DMI: begin d_addr <= rd_data + eac_i.dst_add; done_dmi <= 1'b1; end
					T_SLD: begin s_val <= rd_data; done_sld <= 1'b1; end
					T_DLD: begin d_val <= rd_data; done_dld <= 1'b1; end
					T_SEQ0: begin
						if (ph == P_RESET) x_sp <= rd_data; else r_sr <= rd_data[15:0];
						r_step <= r_step + 3'd1;
					end
					T_SEQ1: begin r_pc <= rd_data; r_step <= r_step + 3'd1; end
					T_SEQ2: begin r_fv <= rd_data[15:0]; r_step <= r_step + 3'd1; end
					T_VEC:  begin x_target <= rd_data; x_step <= 3'd4; end
				endcase
			end
			case (ph)
				P_START: begin
					if (rst_pending) begin
						ph <= P_RESET; r_step <= 3'd0;
					end else if (eac_valid && !(i.serialize && older_busy)) begin
						if (!st.exc_go && i.cls == CL_RTE) begin
							ph <= P_RTE; r_step <= 3'd0;
						end else if (!st.exc_go && !st.fin) ph <= P_OPS;
					end
				end
				P_EXC: begin
					if (x_step <= 3'd2 && st.disp)
						x_step <= (x_step == 3'd1 && x_fmt != 4'd2 && x_fmt != 4'd3) ? 3'd3 : x_step + 3'd1;
					if (x_step == 3'd4 && st.disp && x_target[0]) begin
						// odd handler address: an address error on top (reference
						// S_EXC_JMP), or a double fault for vectors 2 and 3
						if (x_vec == 8'd2 || x_vec == 8'd3) ph <= P_HALT;
						else begin
							x_vec  <= 8'd3; x_fmt <= 4'd2;
							x_pc   <= {22'd0, x_vec, 2'b00};
							x_addr <= {x_target[31:1], 1'b0};
							x_step <= 3'd5;           // wait for the commit, then restart
						end
					end
					if (x_step == 3'd5 && !older_busy) begin
						x_sr   <= sr_in;
						x_bank <= bank_now;
						x_sp   <= rd_a - fsize(x_fmt);  // ra_a = bank_now in P_EXC
						x_step <= 3'd0;
					end
				end
				P_RTE: begin
					if (r_step == 3'd3 && st.disp && !rte_goes) begin
						if (r_fv[15:12] == 4'd1) begin
							ph <= P_START;              // $1: process the next frame after the commit
						end else begin
							// odd PC after the RTE committed SR and SP: address error with the
							// restored SR (reference S_RTE_FIN2), PC = the RTE
							ph <= P_EXC; x_step <= 3'd5;
							x_vec <= 8'd3; x_fmt <= 4'd2; x_pc <= i.pc; x_addr <= {r_pc[31:1], 1'b0};
						end
					end
				end
				P_RESET: begin
					if (r_step == 3'd2 && st.disp) begin
						rst_pending <= 1'b0; ph <= P_START; r_step <= 3'd0;
					end
				end
				default: ;
			endcase
			// an exception starts: step 5 waits for everything older to
			// commit, then latches SR and the supervisor SP
			if (st.exc_go) begin
				ph     <= P_EXC;
				x_vec  <= st.ev; x_fmt <= st.ef; x_pc <= st.epc; x_addr <= st.eaddr;
				x_step <= 3'd5;
			end
			if (st.disp && st.dsel == 3'd0 && two_uop && !st.fin) bf_step <= 1'b1;
			// MOVEM
			if (st0.mm_go && ph != P_MOVEM) begin
				ph       <= P_MOVEM;
				mm_mask  <= mm_16 ? 16'h000F : i.ext;
				mm_empty <= !mm_16 && (i.ext == 16'd0);
				mm_addr  <= mm_16 ? (s_addr_c & ~32'd15) : mm_ld ? s_addr_c : d_addr_c;
				mm_have  <= 1'b0;
				m16_smask <= 4'hF; m16_have <= 4'h0;
				m16_saddr <= d_addr_c & ~32'd15;
			end
			if (ph == P_MOVEM) begin
				if (mms.issue) begin
					mm_rreg  <= mm_sreg; mm_rlast <= mm_one; mm_rk <= mm_k[1:0];
					mm_mask  <= mm_mask & ~(16'd1 << mm_k);
					mm_addr  <= mm_addr + mm_sz;
				end
				if (mm_16 && cap) begin m16_buf[mm_rk] <= rd_data; m16_have[mm_rk] <= 1'b1; end
				if (m16_sd) begin
					m16_smask[m16_ks] <= 1'b0;
					m16_saddr <= m16_saddr + 32'd4;
				end
				if (!mm_lde && mms.disp) begin
					mm_mask  <= mm_mask & ~(16'd1 << mm_k);
					mm_addr  <= mm_pre ? mm_addr - mm_sz : mm_addr + mm_sz;
				end
				if (mms.to_buf) begin
					mm_have <= 1'b1; mm_hdata <= mm_p ? mp_val : rd_data; mm_hreg <= mm_rreg; mm_hlast <= mm_rlast;
				end
				if (mm_p && cap) mp_acc <= {mp_acc[15:0], rd_data[7:0]};
				if (mms.from_buf) mm_have <= 1'b0;
				if (mms.fin) mm_empty <= 1'b0;
			end
			if (st.fin) begin
				ph <= P_START; bf_step <= 1'b0;
				done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
			end
		end
	end
end

endmodule
