//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_decode.v - ID stage (rewritten for Minimig plan M1)                //
//                                                                          //
// Gathers an instruction's words from IF one per clock into a word buffer, //
// and emits the instruction as one id_t once its length is known and every //
// word is present:                                                         //
//   opcode, then "pre" words (immediate data, MOVEC selector, branch        //
//   displacement), then the source EA's extension words, then the          //
//   destination EA's.  The length of a brief/full-format EA is only known  //
//   once its first extension word is in (full format: base and outer       //
//   displacement sizes), so the length is re-evaluated as words arrive.    //
// Up to two words are taken per clock from IF's queue, so an instruction  //
// of one or two words is emitted in the clock it arrives.                  //
//                                                                          //
// Both EAs are normalised to ea_t (ap040_pipe_pkg.sv); PC-relative modes   //
// fold the extension word's address into bd here.                          //
//                                                                          //
// Branch guess: Bcc/BRA/BSR redirect IF to the target the clock they are  //
// emitted (guess taken), exactly as the milestone-4 design; EX recovers.  //
//                                                                          //
// Legality: an opcode this decoder does not implement, or an EA mode the   //
// instruction does not allow, becomes CL_EXC vector 4 with length 1 (the  //
// stacked PC is the opcode's own address, so the length does not matter). //
// $Axxx -> vector 10, $Fxxx -> vector 11 (no FPU/MMU decode yet).          //
//                                                                          //
// M68000PRM section 2 (EA modes, extension word formats), section 4 per    //
// instruction, section 8 opcode map.                                       //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_decode
	import ap040_pipe_pkg::*;
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EA-calc cannot accept this cycle
	input             flush,      // redirect from EX: abandon everything

	// the head of IF's prefetch queue: up to two words
	input             q_v0,
	input             q_v1,
	input      [31:0] q_pc0,
	input      [15:0] q_w0,
	input      [15:0] q_w1,

	output      [1:0] consume,    // words taken from the queue this clock

	output            id_redirect_valid,
	output     [31:0] id_redirect_pc,

	output reg        id_valid,
	output id_t       id_o,
	output     [31:0] g_lo, g_hi,   // words gathered for the next instruction (SMC check)
	output            g_v
);


//------------------------------------------------------------------ helpers

// extension words an EA needs.  ext0 = its first extension word, valid when
// have0; need0 is returned when the answer depends on an ext0 we do not yet
// have.  bad = reserved full-format encoding.
typedef struct packed { logic [3:0] n; logic need0; logic bad; } elen_t;
function automatic elen_t ea_len(input logic [2:0] m, input logic [2:0] r, input logic [1:0] sz,
                                 input logic [15:0] ext0, input logic have0);
	logic full;
	int bdw, odw, n;
	logic need0, bad;
	elen_t e;
	need0 = 1'b0; bad = 1'b0; n = 0;
	full = 1'b0;
	case (m)
		3'd5: n = 1;
		3'd6: full = 1'b1;
		3'd7: case (r)
			3'd0: n = 1;
			3'd1: n = 2;
			3'd2: n = 1;
			3'd3: full = 1'b1;
			3'd4: n = (sz == SZ_L) ? 2 : 1;
			default: n = 0;
		endcase
		default: n = 0;
	endcase
	if (full) begin
		if (!have0) begin
			need0 = 1'b1; n = 1;
		end else if (!ext0[8]) begin
			n = 1;
		end else begin
			bdw = (ext0[5:4] == 2'd3) ? 2 : (ext0[5:4] == 2'd2) ? 1 : 0;
			if (ext0[5:4] == 2'd0 || ext0[3]) bad = 1'b1;
			odw = 0;
			if (!ext0[6]) begin
				case (ext0[2:0])
					3'd2, 3'd6: odw = 1;
					3'd3, 3'd7: odw = 2;
					3'd4: bad = 1'b1;
					default: odw = 0;
				endcase
			end else begin
				case (ext0[2:0])
					3'd2: odw = 1;
					3'd3: odw = 2;
					3'd0, 3'd1: odw = 0;
					default: bad = 1'b1;
				endcase
			end
			n = 1 + bdw + odw;
		end
	end
	e.n = n[3:0]; e.need0 = need0; e.bad = bad;
	return e;
endfunction

// Build an ea_t for mode/reg with its extension words w[k0..], the first
// of which sits at address wpc (the PC-relative base).
function automatic ea_t ea_build(input logic [2:0] m, input logic [2:0] r, input logic [1:0] sz,
                                 input logic [10:0][15:0] w, input int k0, input logic [31:0] wpc);
	ea_t e;
	logic [15:0] x;
	int k;
	logic [31:0] bd, od;
	e = '0;
	e.mode = m; e.mreg = r;
	e.reg_n = {2'b01, r};          // An by default (8 + r)
	e.idx_reg = R_NONE;
	x = w[k0];
	case (m)
		3'd0: begin e.kind = EK_DREG; e.reg_n = {2'b00, r}; end
		3'd1: begin e.kind = EK_AREG; end
		3'd2: begin e.kind = EK_MEM; e.base_en = 1'b1; end
		3'd3: begin e.kind = EK_MEM; e.base_en = 1'b1; e.upd = UPD_POST; end
		3'd4: begin e.kind = EK_MEM; e.base_en = 1'b1; e.upd = UPD_PRE; end
		3'd5: begin e.kind = EK_MEM; e.base_en = 1'b1; e.bd = sext16(x); end
		3'd7: begin
			e.kind = EK_MEM;
			case (r)
				3'd0: e.bd = sext16(x);
				3'd1: e.bd = {x, w[k0 + 1]};
				3'd2: e.bd = wpc + sext16(x);
				3'd4: begin
					e.kind = EK_IMM;
					e.bd = (sz == SZ_L) ? {x, w[k0 + 1]} : (sz == SZ_W) ? {16'd0, x} : {24'd0, x[7:0]};
				end
				default: ;   // 3: indexed PC, below
			endcase
		end
		default: ;
	endcase
	if (m == 3'd6 || (m == 3'd7 && r == 3'd3)) begin
		e.kind = EK_MEM;
		e.base_en = (m == 3'd6);
		e.idx_en = 1'b1;
		e.idx_reg = {1'b0, x[15], x[14:12]};
		e.idx_l = x[11];
		e.scale = x[10:9];
		if (!x[8]) begin
			e.bd = sext8(x[7:0]) + ((m == 3'd7) ? wpc : 32'd0);
		end else begin
			k = k0 + 1;
			bd = 32'd0;
			if (x[5:4] == 2'd2) begin bd = sext16(w[k]); k = k + 1; end
			else if (x[5:4] == 2'd3) begin bd = {w[k], w[k + 1]}; k = k + 2; end
			if (x[7]) e.base_en = 1'b0;                  // BS: base suppressed
			else if (m == 3'd7) bd = bd + wpc;           // PC base (not suppressed)
			if (x[6]) e.idx_en = 1'b0;                   // IS: index suppressed
			e.bd = bd;
			od = 32'd0;
			if (x[1:0] == 2'd2) od = sext16(w[k]);
			else if (x[1:0] == 2'd3) od = {w[k], w[k + 1]};
			e.od = od;
			if (x[2:0] != 3'd0) e.mi = (!x[6] && x[2]) ? MI_POST : MI_PRE;
		end
	end
	return e;
endfunction

// EA class checks (PRM table 2-4): data / memory / control / alterable
function automatic logic ea_ok(input logic [2:0] m, input logic [2:0] r,
                               input logic data, input logic mem, input logic ctl, input logic alt);
	logic is_dn, is_an, is_imm, is_pcrel, valid;
	is_dn = (m == 3'd0); is_an = (m == 3'd1);
	is_imm = (m == 3'd7 && r == 3'd4);
	is_pcrel = (m == 3'd7 && (r == 3'd2 || r == 3'd3));
	valid = (m != 3'd7) || (r <= 3'd4);
	if (!valid) return 1'b0;
	if (data && is_an) return 1'b0;
	if (mem && (is_dn || is_an)) return 1'b0;
	if (ctl && (is_dn || is_an || is_imm || m == 3'd3 || m == 3'd4)) return 1'b0;
	if (alt && (is_imm || is_pcrel)) return 1'b0;
	return 1'b1;
endfunction

//--------------------------------------------------------------- shape

// instruction forms (what decf builds)
localparam [5:0]
	F_ILL = 6'd0,  F_MOVE = 6'd1,  F_MOVEQ = 6'd2, F_BCC = 6'd3,  F_DBCC = 6'd4,
	F_SCC = 6'd5,  F_JMP = 6'd6,   F_JSR = 6'd7,   F_TRAP = 6'd8, F_MOVE2SR = 6'd9,
	F_MOVEC = 6'd10, F_NOP = 6'd11, F_RTE = 6'd12, F_RTS = 6'd13, F_IMM = 6'd14,
	F_IMMCCR = 6'd15, F_IMMSR = 6'd16, F_UNARY = 6'd17, F_CLR = 6'd18, F_TST = 6'd19,
	F_EXT = 6'd20, F_SWAP = 6'd21, F_PEA = 6'd22, F_LEA = 6'd23, F_LINK = 6'd24,
	F_UNLK = 6'd25, F_RTD = 6'd26, F_RTR = 6'd27, F_MOVEFCCR = 6'd28, F_MOVEFSR = 6'd29,
	F_MOVE2CCR = 6'd30, F_ADDQ = 6'd31, F_EA_DN = 6'd32, F_DN_EA = 6'd33, F_ADDA = 6'd34,
	F_ADDX = 6'd35, F_CMPM = 6'd36, F_EXG = 6'd37,
	F_BITD = 6'd38, F_BITS = 6'd39, F_CAS = 6'd40, F_CAS2 = 6'd41, F_CHK2 = 6'd42,
	F_CHK = 6'd43, F_TAS = 6'd44, F_NBCD = 6'd45, F_MDW = 6'd46, F_MDL = 6'd47,
	F_TRAPCC = 6'd48, F_BCD = 6'd49, F_PACK = 6'd50, F_UNPK = 6'd51, F_SHR = 6'd52,
	F_SHM = 6'd53, F_BF = 6'd54, F_MOVEM = 6'd55, F_MOVEUSP = 6'd56, F_MOVEP = 6'd57, F_MOVE16 = 6'd58, F_MOVES = 6'd59, F_CINV = 6'd60;

// What an opcode word implies about the words that follow it.
typedef struct packed {
	logic       ok;        // implemented and legal as far as the opcode word says
	logic [5:0] form;
	logic [5:0] alu;
	logic [1:0] npre;      // words before the EAs
	logic       has_src;
	logic [2:0] sm, sr;    // source EA mode/reg
	logic       has_dst;
	logic [2:0] dm, dr;    // destination EA mode/reg
	logic [1:0] sz;        // operand size (sizes #imm and the EA length)
} shape_t;

// the ALU op of the two-operand groups
function automatic logic [5:0] grp_alu(input logic [3:0] g, input logic eor);
	case (g)
		4'h8: return `AP040_ALU_OR;
		4'h9: return `AP040_ALU_SUB;
		4'hB: return eor ? `AP040_ALU_EOR : `AP040_ALU_CMP;
		4'hC: return `AP040_ALU_AND;
		default: return `AP040_ALU_ADD;   // D
	endcase
endfunction

// shift/rotate ALU op from the type field and the direction bit
function automatic logic [5:0] shift_alu(input logic [1:0] t, input logic left);
	case (t)
		2'b00:   return left ? `AP040_ALU_ASL1  : `AP040_ALU_ASR1;
		2'b01:   return left ? `AP040_ALU_LSL1  : `AP040_ALU_LSR1;
		2'b10:   return left ? `AP040_ALU_ROXL1 : `AP040_ALU_ROXR1;
		default: return left ? `AP040_ALU_ROL1  : `AP040_ALU_ROR1;
	endcase
endfunction

function automatic shape_t shape(input logic [15:0] op);
	shape_t s;
	logic [1:0] ss;
	logic an_ok;
	s = '0;
	s.sm = op[5:3]; s.sr = op[2:0];
	s.dm = op[5:3]; s.dr = op[2:0];
	s.sz = SZ_L;
	ss = op[7:6];
	casez (op)
		//------------------------------------------------ group 0: immediates
		16'h003C, 16'h023C, 16'h0A3C: begin      // ORI/ANDI/EORI #,CCR
			s.ok = 1'b1; s.form = F_IMMCCR; s.npre = 2'd1; s.sz = SZ_B;
			s.alu = (op[11:9] == 3'd0) ? `AP040_ALU_OR : (op[11:9] == 3'd1) ? `AP040_ALU_AND : `AP040_ALU_EOR;
		end
		16'h007C, 16'h027C, 16'h0A7C: begin      // ORI/ANDI/EORI #,SR
			s.ok = 1'b1; s.form = F_IMMSR; s.npre = 2'd1; s.sz = SZ_W;
			s.alu = (op[11:9] == 3'd0) ? `AP040_ALU_OR : (op[11:9] == 3'd1) ? `AP040_ALU_AND : `AP040_ALU_EOR;
		end
		16'b0000_1000_11??_????: begin           // BSET #,<ea> (before CAS: 0000 1ss0 11, ss=00 is BSET)
			s.form = F_BITS; s.npre = 2'd1; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B; s.alu = `AP040_ALU_BSET;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_1110_0???_????, 16'b0000_1110_10??_????: begin   // MOVES <memory alterable> (before CAS)
			s.form = F_MOVES; s.npre = 2'd1; s.sz = op[7:6]; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b0000_1??0_1111_1100: begin           // CAS2 (W/L): two extension words
			s.form = F_CAS2; s.npre = 2'd2; s.alu = `AP040_ALU_CMP;
			s.sz = op[9] ? SZ_L : SZ_W;
			s.ok = op[10];                        // 10 word, 11 long (no byte form)
		end
		16'b0000_1??0_11??_????: begin           // CAS Dc,Du,<memory alterable>
			s.form = F_CAS; s.npre = 2'd1; s.has_dst = 1'b1; s.alu = `AP040_ALU_CMP;
			s.sz = (op[10:9] == 2'b01) ? SZ_B : (op[10:9] == 2'b10) ? SZ_W : SZ_L;
			s.ok = (op[10:9] != 2'b00) && ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b0000_0??0_11??_????: begin           // CHK2 / CMP2 <control>,Rn
			s.form = F_CHK2; s.npre = 2'd1; s.has_src = 1'b1;
			s.sz = op[10:9];
			s.ok = (op[10:9] != 2'b11) && ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0000_1000_????_????: begin           // BTST/BCHG/BCLR/BSET #,<ea>
			s.form = F_BITS; s.npre = 2'd1; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B;
			s.alu = (op[7:6] == 2'd0) ? `AP040_ALU_BTST : (op[7:6] == 2'd1) ? `AP040_ALU_BCHG :
			        (op[7:6] == 2'd2) ? `AP040_ALU_BCLR : `AP040_ALU_BSET;
			// BTST #,<ea>: data except #imm (PC relative allowed); the others data alterable
			s.ok = (op[7:6] == 2'd0) ? (ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0) && !(s.dm == 3'd7 && s.dr == 3'd4))
			                         : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_???1_??00_1???: begin           // MOVEP: the displacement word is the only extension
			s.ok = 1'b1; s.form = F_MOVEP; s.npre = 2'd1; s.sz = op[6] ? SZ_L : SZ_W;
		end
		16'b0000_???1_????_????: begin           // BTST/BCHG/BCLR/BSET Dn,<ea>
			s.form = F_BITD; s.has_dst = 1'b1;
			s.sz = (s.dm == 3'd0) ? SZ_L : SZ_B;
			s.alu = (op[7:6] == 2'd0) ? `AP040_ALU_BTST : (op[7:6] == 2'd1) ? `AP040_ALU_BCHG :
			        (op[7:6] == 2'd2) ? `AP040_ALU_BCLR : `AP040_ALU_BSET;
			// BTST Dn,<ea>: any data EA incl. #imm and PC relative
			s.ok = (op[7:6] == 2'd0) ? ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0)
			                         : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0000_???0_????_????: begin           // ORI ANDI SUBI ADDI EORI CMPI #,<ea>
			if (ss != 2'b11 && op[11:9] != 3'd4 && op[11:9] != 3'd7) begin
				s.form = F_IMM; s.sz = ss; s.npre = (ss == SZ_L) ? 2'd2 : 2'd1; s.has_dst = 1'b1;
				case (op[11:9])
					3'd0: s.alu = `AP040_ALU_OR;   3'd1: s.alu = `AP040_ALU_AND;
					3'd2: s.alu = `AP040_ALU_SUB;  3'd3: s.alu = `AP040_ALU_ADD;
					3'd5: s.alu = `AP040_ALU_EOR;  default: s.alu = `AP040_ALU_CMP;
				endcase
				// CMPI: data EA, PC-relative allowed (68020+); the others data alterable
				s.ok = (op[11:9] == 3'd6) ? (ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b0) && !(s.dm == 3'd7 && s.dr == 3'd4))
				                          : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
			end
		end
		//------------------------------------------------ MOVE / MOVEA
		16'b0001_????_????_????, 16'b0010_????_????_????, 16'b0011_????_????_????: begin
			s.form = F_MOVE; s.alu = `AP040_ALU_MOVE;
			s.sz = (op[13:12] == 2'b01) ? SZ_B : (op[13:12] == 2'b11) ? SZ_W : SZ_L;
			s.has_src = 1'b1; s.has_dst = 1'b1;
			s.dm = op[8:6]; s.dr = op[11:9];
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) &&
			       !(s.sz == SZ_B && s.sm == 3'd1) &&
			       ((s.dm == 3'd1) ? (s.sz != SZ_B) : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1));
		end
		//------------------------------------------------ group 4
		16'b0100_0000_11??_????: begin           // MOVE SR,<ea>
			s.form = F_MOVEFSR; s.sz = SZ_W; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0010_11??_????: begin           // MOVE CCR,<ea>
			s.form = F_MOVEFCCR; s.sz = SZ_W; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0100_11??_????: begin           // MOVE <ea>,CCR
			s.form = F_MOVE2CCR; s.sz = SZ_W; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_0110_11??_????: begin           // MOVE <ea>,SR
			s.form = F_MOVE2SR; s.sz = SZ_W; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_0000_????_????, 16'b0100_0100_????_????, 16'b0100_0110_????_????: begin  // NEGX NEG NOT
			s.form = F_UNARY; s.sz = ss; s.has_dst = 1'b1;
			s.alu = (op[10:9] == 2'b00) ? `AP040_ALU_NEGX : (op[10:9] == 2'b10) ? `AP040_ALU_NEG : `AP040_ALU_NOT;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_0010_????_????: begin           // CLR
			s.form = F_CLR; s.sz = ss; s.has_dst = 1'b1; s.alu = `AP040_ALU_CLR;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1000_0000_1???: begin s.ok = 1'b1; s.form = F_LINK; s.npre = 2'd2; end  // LINK.L
		16'b0100_1000_0100_0???: begin s.ok = 1'b1; s.form = F_SWAP; s.alu = `AP040_ALU_SWAP; end
		16'b0100_1000_01??_????: begin           // PEA <ctl>
			s.form = F_PEA; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1000_1000_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_W; s.alu = `AP040_ALU_EXT; end
		16'b0100_1000_1100_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_L; s.alu = `AP040_ALU_EXT; end
		// MOVEM (after EXT, which is its Dn mode): mask word first, then the EA
		16'b0100_1000_1???_????: begin           // MOVEM regs,<ctl alterable> / -(An)
			s.form = F_MOVEM; s.npre = 2'd1; s.has_dst = 1'b1; s.sz = op[6] ? SZ_L : SZ_W;
			s.ok = (s.dm == 3'd4) || (s.dm != 3'd3 && ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b1));
		end
		16'b0100_1100_1???_????: begin           // MOVEM <ctl> / (An)+,regs
			s.form = F_MOVEM; s.npre = 2'd1; s.has_src = 1'b1; s.sz = op[6] ? SZ_L : SZ_W;
			s.ok = (s.sm == 3'd3) || (s.sm != 3'd4 && ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0));
		end
		16'b0100_1001_1100_0???: begin s.ok = 1'b1; s.form = F_EXT; s.sz = SZ_L; s.alu = `AP040_ALU_EXTB; end
		16'h4AFC: s.ok = 1'b0;                   // ILLEGAL (vector 4)
		16'b0100_1010_11??_????: begin           // TAS <data alterable>
			s.form = F_TAS; s.sz = SZ_B; s.has_dst = 1'b1; s.alu = `AP040_ALU_TAS;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1000_00??_????: begin           // NBCD <data alterable> (mode 001 = LINK.L, above)
			s.form = F_NBCD; s.sz = SZ_B; s.has_dst = 1'b1; s.alu = `AP040_ALU_NBCD;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0100_1100_00??_????, 16'b0100_1100_01??_????: begin   // MUL.L / DIV.L <data>
			s.form = F_MDL; s.npre = 2'd1; s.has_src = 1'b1; s.sz = SZ_L;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b0100_???1_10??_????, 16'b0100_???1_00??_????: begin   // CHK.W / CHK.L <data>,Dn
			s.form = F_CHK; s.has_src = 1'b1; s.sz = op[7] ? SZ_W : SZ_L;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'h4E76: begin s.ok = 1'b1; s.form = F_TRAPCC; end    // TRAPV
		16'b0100_1010_????_????: begin           // TST <ea> (68020+: An for W/L, #imm, PC relative)
			s.form = F_TST; s.sz = ss; s.has_src = 1'b1; s.alu = `AP040_ALU_TST;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) && !(ss == SZ_B && s.sm == 3'd1);
		end
		16'b0100_???1_11??_????: begin           // LEA <ctl>,An
			s.form = F_LEA; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1110_0101_0???: begin s.ok = 1'b1; s.form = F_LINK; s.npre = 2'd1; end  // LINK.W
		16'b0100_1110_0101_1???: begin s.ok = 1'b1; s.form = F_UNLK; end
		16'h4E74: begin s.ok = 1'b1; s.form = F_RTD; s.npre = 2'd1; end
		16'h4E77: begin s.ok = 1'b1; s.form = F_RTR; end
		16'b0100_1110_11??_????, 16'b0100_1110_10??_????: begin   // JMP / JSR <ctl>
			s.form = op[6] ? F_JMP : F_JSR; s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		16'b0100_1110_0100_????: begin s.ok = 1'b1; s.form = F_TRAP; end
		16'b0100_1110_0111_101?: begin s.ok = 1'b1; s.form = F_MOVEC; s.npre = 2'd1; end
		16'b0100_1110_0110_????: begin s.ok = 1'b1; s.form = F_MOVEUSP; end   // MOVE An,USP / USP,An
		// CINV/CPUSH (scope 01 line, 10 page, 11 all): a privileged, serialising
		// no-op until M8 connects them to the caches (t_integer.s needs CINVA)
		16'b1111_0100_???0_1???, 16'b1111_0100_???1_0???, 16'b1111_0100_???1_1???: begin
			s.ok = 1'b1; s.form = F_CINV;
		end
		16'b1111_0110_0010_0???: begin s.ok = 1'b1; s.form = F_MOVE16; s.npre = 2'd1; s.sz = SZ_L; end  // (Ax)+,(Ay)+
		16'b1111_0110_000?_????: begin s.ok = 1'b1; s.form = F_MOVE16; s.npre = 2'd2; s.sz = SZ_L; end  // abs.L forms
		16'h4E71: begin s.ok = 1'b1; s.form = F_NOP; end
		16'h4E73: begin s.ok = 1'b1; s.form = F_RTE; end
		16'h4E75: begin s.ok = 1'b1; s.form = F_RTS; end
		//------------------------------------------------ group 5
		16'b0101_????_1100_1???: begin s.ok = 1'b1; s.form = F_DBCC; s.npre = 2'd1; end
		16'b0101_????_1111_1010: begin s.ok = 1'b1; s.form = F_TRAPCC; s.npre = 2'd1; end   // TRAPcc.W
		16'b0101_????_1111_1011: begin s.ok = 1'b1; s.form = F_TRAPCC; s.npre = 2'd2; end   // TRAPcc.L
		16'b0101_????_1111_1100: begin s.ok = 1'b1; s.form = F_TRAPCC; end                 // TRAPcc
		16'b0101_????_11??_????: begin           // Scc <data alterable>
			s.form = F_SCC; s.sz = SZ_B; s.has_dst = 1'b1;
			s.ok = ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1);
		end
		16'b0101_????_????_????: begin           // ADDQ / SUBQ #,<alterable>
			s.form = F_ADDQ; s.sz = ss; s.has_dst = 1'b1;
			s.alu = op[8] ? `AP040_ALU_SUB : `AP040_ALU_ADD;
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b0, 1'b1) && !(ss == SZ_B && s.dm == 3'd1);
		end
		//------------------------------------------------ Bcc / MOVEQ
		16'b0110_????_????_????: begin
			s.ok = 1'b1; s.form = F_BCC;
			s.npre = (op[7:0] == 8'h00) ? 2'd1 : (op[7:0] == 8'hFF) ? 2'd2 : 2'd0;
		end
		16'b0111_???0_????_????: begin s.ok = 1'b1; s.form = F_MOVEQ; end
		//------------------------------------------------ two-operand groups 8 9 B C D
		16'b1100_???1_0100_0???, 16'b1100_???1_0100_1???, 16'b1100_???1_1000_1???: begin
			s.ok = 1'b1; s.form = F_EXG;
		end
		16'b1001_????_11??_????, 16'b1011_????_11??_????, 16'b1101_????_11??_????: begin  // SUBA CMPA ADDA
			s.form = F_ADDA; s.sz = op[8] ? SZ_L : SZ_W; s.has_src = 1'b1;
			s.alu = grp_alu(op[15:12], 1'b0);
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0);
		end
		16'b1011_???1_??00_1???: begin           // CMPM (Ay)+,(Ax)+
			s.form = F_CMPM; s.sz = ss; s.ok = (ss != 2'b11); s.alu = `AP040_ALU_CMP;
		end
		16'b1001_???1_??00_????, 16'b1101_???1_??00_????: begin   // SUBX / ADDX (register or -(An))
			s.form = F_ADDX; s.sz = ss; s.ok = (ss != 2'b11);
			s.alu = op[14] ? `AP040_ALU_ADDX : `AP040_ALU_SUBX;
		end
		16'b1000_???0_11??_????, 16'b1000_???1_11??_????,
		16'b1100_???0_11??_????, 16'b1100_???1_11??_????: begin   // DIVU/DIVS.W, MULU/MULS.W <data>,Dn
			s.form = F_MDW; s.has_src = 1'b1; s.sz = SZ_W;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		16'b1000_???1_0000_????, 16'b1100_???1_0000_????: begin   // SBCD / ABCD (Dy,Dx or -(Ay),-(Ax))
			s.ok = 1'b1; s.form = F_BCD; s.sz = SZ_B;
			s.alu = op[14] ? `AP040_ALU_ABCD : `AP040_ALU_SBCD;
		end
		16'b1000_???1_0100_????: begin s.ok = 1'b1; s.form = F_PACK; s.npre = 2'd1; end
		16'b1000_???1_1000_????: begin s.ok = 1'b1; s.form = F_UNPK; s.npre = 2'd1; end
		16'b1000_???1_??00_????, 16'b1100_???1_??00_????: s.ok = 1'b0;  // reserved
		16'b1000_????_????_????, 16'b1001_????_????_????, 16'b1011_????_????_????,
		16'b1100_????_????_????, 16'b1101_????_????_????: begin
			if (ss != 2'b11) begin
				s.sz = ss;
				if (!op[8] || op[15:12] == 4'hB && !op[8]) begin      // <ea>,Dn
					s.form = F_EA_DN; s.has_src = 1'b1;
					s.alu = grp_alu(op[15:12], 1'b0);
					an_ok = (op[15:12] == 4'h9 || op[15:12] == 4'hB || op[15:12] == 4'hD) && ss != SZ_B;
					s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) && (s.sm != 3'd1 || an_ok);
				end else begin                  // Dn,<ea>  (EOR: data alterable incl. Dn)
					s.form = F_DN_EA; s.has_dst = 1'b1;
					s.alu = grp_alu(op[15:12], 1'b1);
					s.ok = (op[15:12] == 4'hB) ? ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1)
					                           : ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
				end
			end
		end
		//------------------------------------------------ group E: shifts, bitfields
		16'b1110_1???_11??_????: begin           // bitfields: extension word first
			s.form = F_BF; s.npre = 2'd1; s.has_dst = 1'b1; s.sz = SZ_L;
			// Dn or a control EA; CHG/CLR/SET/INS need it alterable (no PC relative)
			s.ok = (s.dm == 3'd0) ||
			       ((op[8] == 1'b0 && op[10:9] != 2'b00) || op[10:8] == 3'b110 || op[10:8] == 3'b111 ?
			        ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b1) :
			        ea_ok(s.dm, s.dr, 1'b0, 1'b0, 1'b1, 1'b0));
		end
		16'b1110_0???_11??_????: begin           // memory shift/rotate by one, word
			s.form = F_SHM; s.sz = SZ_W; s.has_dst = 1'b1;
			s.alu = shift_alu(op[10:9], op[8]);
			s.ok = ea_ok(s.dm, s.dr, 1'b0, 1'b1, 1'b0, 1'b1);
		end
		16'b1110_????_????_????: begin           // register shift/rotate
			s.ok = 1'b1; s.form = F_SHR; s.sz = ss;
			s.alu = shift_alu(op[4:3], op[8]);
		end
		default: s.ok = 1'b0;
	endcase
	return s;
endfunction

//--------------------------------------------------------------- gather
//
// Combinational logic here is written as PURE functions (every input an
// argument) assigned with assign: Icarus derives a continuous assignment's
// sensitivity from the arguments only, and an always block that calls a
// function while reading a variable it writes can re-trigger itself forever
// (found on the first run of this file).

reg [10:0][15:0] wbuf;     // words gathered so far (word 0 = opcode)
reg        [3:0] wcnt;     // how many
reg       [31:0] g_pc;     // address of word 0

// the buffer as it will be with the incoming word appended
function automatic logic [10:0][15:0] view(input logic [10:0][15:0] wb, input logic [3:0] n,
                                           input logic [1:0] tk, input logic [15:0] w0,
                                           input logic [15:0] w1);
	logic [10:0][15:0] v;
	v = wb;
	if (tk >= 2'd1 && n <= 4'd10) v[n] = w0;
	if (tk == 2'd2 && n <= 4'd9)  v[n + 1] = w1;
	return v;
endfunction

// words available this clock (the queue hands them out in order)
wire        [1:0] avail  = q_v0 ? (q_v1 ? 2'd2 : 2'd1) : 2'd0;
wire        [3:0] vcnt   = wcnt + {2'd0, avail};
wire [10:0][15:0] vbuf   = view(wbuf, wcnt, avail, q_w0, q_w1);
wire       [31:0] vpc    = (wcnt == 4'd0) ? q_pc0 : g_pc;

// total length of the instruction in the view, if known
typedef struct packed {
	shape_t      sh;
	logic [4:0]  tot;      // total words needed (valid when !more)
	logic        more;     // need at least one more word before tot is known
	logic        ea_bad;
} len_t;

function automatic len_t lenf(input logic [10:0][15:0] vb, input logic [3:0] vc);
	len_t l; elen_t e; int k;
	l = '0;
	l.sh = shape(vb[0]);
	k = 1 + l.sh.npre;
	if (l.sh.ok && l.sh.has_src) begin
		e = ea_len(l.sh.sm, l.sh.sr, l.sh.sz, vb[k], (vc > k));
		if (e.need0) l.more = 1'b1;
		l.ea_bad = l.ea_bad | e.bad;
		k = k + e.n;
	end
	if (l.sh.ok && l.sh.has_dst && !l.more) begin
		e = ea_len(l.sh.dm, l.sh.dr, l.sh.sz, vb[k], (vc > k));
		if (e.need0) l.more = 1'b1;
		l.ea_bad = l.ea_bad | e.bad;
		k = k + e.n;
	end
	l.tot = l.sh.ok ? k[4:0] : 5'd1;
	return l;
endfunction

wire len_t   ln  = lenf(vbuf, vcnt);
wire shape_t sh  = ln.sh;
wire [4:0]   tot = ln.tot;
wire complete = (vcnt != 4'd0) && !ln.more && ({1'b0, vcnt} >= tot);

//--------------------------------------------------------------- decode

function automatic ea_t ea_reg(input logic [2:0] kind, input logic [4:0] r);
	ea_t e;
	e = '0; e.kind = kind; e.reg_n = r; e.idx_reg = R_NONE;
	e.mode = (kind == EK_AREG) ? 3'd1 : 3'd0; e.mreg = r[2:0];
	return e;
endfunction

function automatic ea_t ea_imm(input logic [31:0] v);
	ea_t e;
	e = '0; e.kind = EK_IMM; e.bd = v; e.reg_n = R_NONE; e.idx_reg = R_NONE;
	e.mode = 3'd7; e.mreg = 3'd4;
	return e;
endfunction

// (An) / (An)+ / -(An) / (d,An) on A7, for the implied stack operands
function automatic ea_t ea_sp(input logic [1:0] upd, input logic [31:0] disp);
	ea_t e;
	e = '0; e.kind = EK_MEM; e.base_en = 1'b1; e.reg_n = R_A7L; e.upd = upd; e.bd = disp;
	e.idx_reg = R_NONE;
	e.mode = (upd == UPD_PRE) ? 3'd4 : (upd == UPD_POST) ? 3'd3 : 3'd2; e.mreg = 3'd7;
	return e;
endfunction

function automatic id_t decf(input logic [10:0][15:0] vbuf, input logic [31:0] vpc,
                             input shape_t sh, input logic [4:0] tot_w, input logic ea_bad);
	id_t d;
	int tot;
	logic [15:0] op, x1;
	logic [31:0] ipre;
	logic        s2set;        // the destination EA has its own size (size2)
	logic [1:0]  s2;
	int ks, kd; elen_t e;
	tot = tot_w;
	op = vbuf[0];
	x1 = vbuf[1];
	d = '0;
	s2set = 1'b0; s2 = SZ_L;
	d.reg_c = R_NONE;
	d.reg_d = R_NONE;
	d.pc = vpc;
	d.next_pc = vpc + 32'(2 * tot);
	d.opcode = op;
	d.ext = x1;
	d.size = sh.sz;
	d.alu = sh.alu;
	d.cond = op[11:8];
	d.src.idx_reg = R_NONE; d.dst.idx_reg = R_NONE;
	d.src.reg_n = R_NONE; d.dst.reg_n = R_NONE;
	// the pre-EA immediate (B: low byte of word 1, W: word 1, L: words 1-2)
	ipre = (sh.sz == SZ_L) ? {x1, vbuf[2]} : (sh.sz == SZ_W) ? {16'd0, x1} : {24'd0, x1[7:0]};
	// EA words
	ks = 1 + sh.npre;
	e = ea_len(sh.sm, sh.sr, sh.sz, vbuf[ks], 1'b1);
	kd = ks + (sh.has_src ? int'(e.n) : 0);
	if (sh.has_src) d.src = ea_build(sh.sm, sh.sr, sh.sz, vbuf, ks, vpc + 32'(2 * ks));
	if (sh.has_dst) d.dst = ea_build(sh.dm, sh.dr, sh.sz, vbuf, kd, vpc + 32'(2 * kd));
	d.cls = CL_EXC; d.exc_vec = 8'd4;           // default: illegal
	if (op[15:12] == 4'hA) d.exc_vec = 8'd10;   // A-line
	if (op[15:12] == 4'hF) d.exc_vec = 8'd11;   // F-line (no FPU yet)
	if (sh.ok && !ea_bad) begin
		case (sh.form)
			F_MOVE: begin
				d.cls = CL_ALU;
				d.wr_ccr = (sh.dm != 3'd1);         // MOVEA leaves the CCR alone
			end
			F_MOVEQ: begin
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE; d.size = SZ_L; d.wr_ccr = 1'b1;
				d.src = ea_imm(sext8(op[7:0]));
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_IMM: begin                        // #imm,<ea>; CMPI writes nothing
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_imm(ipre);
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_IMMCCR: begin d.cls = CL_CCROP; d.src = ea_imm({24'd0, x1[7:0]}); end
			F_IMMSR:  begin d.cls = CL_SROP; d.priv = 1'b1; d.serialize = 1'b1; d.src = ea_imm({16'd0, x1}); end
			F_UNARY: begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; end
			F_CLR:   begin d.cls = CL_ALU; d.wr_ccr = 1'b1; end   // a pure write on the 68040
			F_TST:   begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.nowrite = 1'b1; end
			F_EXT, F_SWAP: begin
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
			end
			F_PEA: begin
				d.cls = CL_PEA; d.size = SZ_L;
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_LEA: begin
				d.cls = CL_LEA; d.size = SZ_L;
				d.dst = ea_reg(EK_AREG, {2'b01, op[11:9]});
			end
			F_LINK: begin                       // push An, An = SP, SP += d
				d.cls = CL_LINK; d.size = SZ_L;
				d.imm = (op[15:8] == 8'h48) ? {x1, vbuf[2]} : sext16(x1);
				d.src = ea_reg(EK_AREG, {2'b01, op[2:0]});
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_UNLK: begin                       // SP = An + 4, An = (An)
				d.cls = CL_UNLK; d.size = SZ_L;
				d.src = '0; d.src.kind = EK_MEM; d.src.base_en = 1'b1; d.src.reg_n = {2'b01, op[2:0]};
				d.src.idx_reg = R_NONE; d.src.mode = 3'd2; d.src.mreg = op[2:0];
				d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]});
			end
			F_RTS: begin d.cls = CL_RTS; d.size = SZ_L; d.src = ea_sp(UPD_POST, 32'd0); end
			F_RTD: begin
				d.cls = CL_RTD; d.size = SZ_L; d.src = ea_sp(UPD_POST, 32'd0);
				d.imm = sext16(x1);
			end
			F_RTR: begin                        // CCR from (SP), PC from 2(SP), SP += 6
				d.cls = CL_RTR; d.size = SZ_W; d.src = ea_sp(UPD_NONE, 32'd0);
				s2set = 1'b1; s2 = SZ_L;         // the PC at 2(SP) is a long
				d.dst = ea_sp(UPD_NONE, 32'd2); d.rmw = 1'b1;
			end
			F_MOVEFCCR: begin d.cls = CL_MOVEFSR; d.ccr_only = 1'b1; end
			F_MOVEFSR:  begin d.cls = CL_MOVEFSR; d.priv = 1'b1; end
			F_MOVE2CCR: d.cls = CL_MOVE2CCR;
			F_MOVE2SR:  begin d.cls = CL_MOVE2SR; d.priv = 1'b1; d.serialize = 1'b1; end
			F_ADDQ: begin                       // #1-8; to An: long, no CCR
				d.cls = CL_ALU; d.rmw = 1'b1;
				d.src = ea_imm({28'd0, (op[11:9] == 3'd0), op[11:9]});
				d.wr_ccr = (sh.dm != 3'd1);
				if (sh.dm == 3'd1) d.size = SZ_L;
			end
			F_EA_DN: begin                      // <ea>,Dn; CMP writes nothing
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_DN_EA: begin                      // Dn,<ea>
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_ADDA: begin                       // ADDA/SUBA: no CCR; CMPA: CCR only
				d.cls = CL_ALU; d.rmw = 1'b1;
				d.dst = ea_reg(EK_AREG, {2'b01, op[11:9]});
				d.wr_ccr  = (sh.alu == `AP040_ALU_CMP);
				d.nowrite = (sh.alu == `AP040_ALU_CMP);
			end
			F_ADDX: begin                       // Dy,Dx or -(Ay),-(Ax)
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], sh.sz, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], sh.sz, vbuf, 1, vpc);
				end
			end
			F_CMPM: begin                       // (Ay)+,(Ax)+
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; d.nowrite = 1'b1;
				d.src = ea_build(3'd3, op[2:0], sh.sz, vbuf, 1, vpc);
				d.dst = ea_build(3'd3, op[11:9], sh.sz, vbuf, 1, vpc);
			end
			F_EXG: begin
				d.cls = CL_EXG; d.size = SZ_L;
				case (op[7:3])
					5'b01000: begin d.src = ea_reg(EK_DREG, {2'b00, op[11:9]}); d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]}); end
					5'b01001: begin d.src = ea_reg(EK_AREG, {2'b01, op[11:9]}); d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]}); end
					default:  begin d.src = ea_reg(EK_DREG, {2'b00, op[11:9]}); d.dst = ea_reg(EK_AREG, {2'b01, op[2:0]}); end
				endcase
			end
			//-------------------------------------------- M3
			F_BITD, F_BITS: begin               // bit number from Dn or #; mod 32 (Dn) / 8 (memory) in EX
				d.cls = CL_BIT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = (sh.form == F_BITD) ? ea_reg(EK_DREG, {2'b00, op[11:9]}) : ea_imm({24'd0, x1[7:0]});
				d.nowrite = (sh.alu == `AP040_ALU_BTST);
			end
			F_CAS: begin                        // CAS Dc,Du,<ea>: Dc = src, Du = reg_c
				d.cls = CL_CAS; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_reg(EK_DREG, {2'b00, x1[2:0]});
				d.reg_c = {2'b00, x1[8:6]};
			end
			F_CHK2: begin                       // bounds at <ea>, <ea>+size; Rn from the ext word
				d.cls = CL_CHK2; d.wr_ccr = 1'b1; d.nowrite = 1'b1;
				d.dst = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
			end
			F_CHK: begin                        // bound = src, Dn = dst (read only)
				d.cls = CL_CHK; d.wr_ccr = 1'b1; d.nowrite = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
			end
			F_TAS, F_NBCD: begin d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1; end
			F_MDW: begin                        // 16 x 16 -> 32, 32 / 16 -> 16r:16q
				d.cls = CL_MULDIV; d.wr_ccr = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				d.imm[0] = !op[14];             // divide (group 8)
				d.imm[1] = op[8];               // signed
			end
			F_MDL: begin                        // MUL.L / DIV.L: Dl/Dq in ext 14:12, Dh/Dr in 2:0
				d.cls = CL_MULDIV; d.wr_ccr = 1'b1;
				d.dst = ea_reg(EK_DREG, {2'b00, x1[14:12]});
				d.reg_c = {2'b00, x1[2:0]};
				d.imm[0] = op[6];               // divide
				d.imm[1] = x1[11];              // signed
				d.imm[2] = 1'b1;                // long form
				d.imm[3] = x1[10];              // 64-bit (Dh:Dl product / Dr:Dq dividend)
			end
			F_TRAPCC: begin
				d.cls = CL_TRAPCC;
				if (op == 16'h4E76) d.cond = 4'h9;   // TRAPV: V set
			end
			F_BCD: begin                        // ABCD/SBCD Dy,Dx or -(Ay),-(Ax)
				d.cls = CL_ALU; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], SZ_B, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], SZ_B, vbuf, 1, vpc);
				end
			end
			F_PACK, F_UNPK: begin               // Dy,Dx,#adj or -(Ay),-(Ax),#adj
				d.cls = (sh.form == F_PACK) ? CL_PACK : CL_UNPK;
				d.imm = {16'd0, x1};
				d.size = (sh.form == F_PACK) ? SZ_W : SZ_B;    // the source
				s2set = 1'b1; s2 = (sh.form == F_PACK) ? SZ_B : SZ_W;   // the destination
				if (!op[3]) begin
					d.src = ea_reg(EK_DREG, {2'b00, op[2:0]});
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.src = ea_build(3'd4, op[2:0], d.size, vbuf, 1, vpc);
					d.dst = ea_build(3'd4, op[11:9], s2, vbuf, 1, vpc);
				end
			end
			F_SHR: begin                        // count #1-8 or Dn (mod 64), Dn destination
				d.cls = CL_SHIFT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = op[5] ? ea_reg(EK_DREG, {2'b00, op[11:9]}) : ea_imm({28'd0, (op[11:9] == 3'd0), op[11:9]});
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
			end
			F_MOVE16: begin                     // run by the MOVEM sequencer: imm[2] = MOVE16
				// imm[3]/imm[4]: the source / destination register is postincremented by 16
				d.cls = CL_MOVEM; d.size = SZ_L;
				if (op[5]) begin                  // MOVE16 (Ax)+,(Ay)+
					d.imm = {27'd0, 1'b1, 1'b1, 1'b1, 2'b00};
					d.src = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.src.base_en = 1'b1; d.src.mode = 3'd2;
					d.dst = ea_reg(EK_MEM, {2'b01, x1[14:12]}); d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
				end else begin
					// opmode 00 (Ay)+ -> abs, 01 abs -> (Ay)+, 10 (Ay) -> abs, 11 abs -> (Ay)
					d.imm = {27'd0, (op[4:3] == 2'b01), (op[4:3] == 2'b00), 1'b1, 2'b00};
					if (op[3]) begin
						d.src = ea_imm({x1, vbuf[2]}); d.src.kind = EK_MEM;
						d.dst = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
					end else begin
						d.src = ea_reg(EK_MEM, {2'b01, op[2:0]}); d.src.base_en = 1'b1; d.src.mode = 3'd2;
						d.dst = ea_imm({x1, vbuf[2]}); d.dst.kind = EK_MEM;
					end
				end
			end
			F_MOVEP: begin                      // run by the MOVEM sequencer: imm[1] = MOVEP
				d.cls = CL_MOVEM; d.imm = {30'd0, 1'b1, !op[7]};
				d.ext = op[6] ? 16'h000F : 16'h0003;   // 4 or 2 bytes
				if (!op[7]) begin
					d.src = ea_build(3'd5, op[2:0], SZ_B, vbuf, 1, vpc + 32'd2);
					d.dst = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end else begin
					d.dst = ea_build(3'd5, op[2:0], SZ_B, vbuf, 1, vpc + 32'd2);
					d.src = ea_reg(EK_DREG, {2'b00, op[11:9]});
				end
			end
			F_MOVEM: begin                      // imm[0]: memory to registers; ext = the mask
				d.cls = CL_MOVEM; d.imm = {31'd0, op[10]};
			end
			F_CAS2: begin                       // CAS2 Dc1:Dc2,Du1:Du2,(Rn1):(Rn2)
				d.cls = CL_CAS2; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.ext2 = vbuf[2];
				d.src = ea_reg(EK_MEM, {1'b0, x1[15], x1[14:12]});             // (Rn1)
				d.src.base_en = 1'b1; d.src.mode = 3'd2;
				d.dst = ea_reg(EK_MEM, {1'b0, vbuf[2][15], vbuf[2][14:12]});   // (Rn2)
				d.dst.base_en = 1'b1; d.dst.mode = 3'd2;
				d.reg_c = {2'b00, x1[8:6]};                                    // Du1
				d.reg_d = {2'b00, vbuf[2][8:6]};                               // Du2
			end
			F_BF: begin                         // field at Dn or <ea>; ext: Dn, Do/offset, Dw/width
				d.cls = CL_BF; d.wr_ccr = 1'b1;
				d.alu = {3'd0, op[10:8]};         // 0 TST 1 EXTU 2 CHG 3 EXTS 4 CLR 5 FFO 6 SET 7 INS
				d.src = ea_reg(EK_DREG, {2'b00, x1[14:12]});   // INS source / EXTU EXTS FFO destination
				d.reg_c = x1[11] ? {2'b00, x1[8:6]} : R_NONE;  // offset in Dn
				d.reg_d = x1[5]  ? {2'b00, x1[2:0]} : R_NONE;  // width in Dn
			end
			F_SHM: begin                        // <ea> by one, word
				d.cls = CL_SHIFT; d.wr_ccr = 1'b1; d.rmw = 1'b1;
				d.src = ea_imm(32'd1);
			end
			F_BCC: begin                        // Bcc / BRA / BSR
				d.cls = (op[11:8] == 4'h1) ? CL_BSR : CL_BCC;
				d.btarget = vpc + 32'd2 + ((op[7:0] == 8'h00) ? sext16(x1) :
				                           (op[7:0] == 8'hFF) ? {x1, vbuf[2]} : sext8(op[7:0]));
				if (op[11:8] == 4'h1) begin      // BSR: the push is a store to -(A7)
					d.size = SZ_L;
					d.dst = ea_sp(UPD_PRE, 32'd0);
				end
			end
			F_DBCC: begin
				d.cls = CL_DBCC; d.size = SZ_W;
				d.dst = ea_reg(EK_DREG, {2'b00, op[2:0]});
				d.btarget = vpc + 32'd2 + sext16(x1);
			end
			F_SCC: d.cls = CL_SCC;
			F_JMP: begin d.cls = CL_JMP; d.size = SZ_L; end
			F_JSR: begin                        // JSR: the push is a store to -(A7)
				d.cls = CL_JSR; d.size = SZ_L;
				d.dst = ea_sp(UPD_PRE, 32'd0);
			end
			F_TRAP: begin d.cls = CL_EXC; d.exc_vec = 8'd32 + {4'd0, op[3:0]}; d.exc_next = 1'b1; end
			F_MOVEC: begin
				d.cls = CL_MOVEC; d.priv = 1'b1; d.serialize = 1'b1;
				case (x1[11:0])
					12'h000: d.imm[3:0] = CR_SFC;
					12'h001: d.imm[3:0] = CR_DFC;
					12'h002: d.imm[3:0] = CR_CACR;
					12'h801: d.imm[3:0] = CR_VBR;
					12'h800: d.imm[3:0] = CR_USP;
					12'h804: d.imm[3:0] = CR_ISP;
					12'h803: d.imm[3:0] = CR_MSP;
					// the MMU registers are accepted and stored before M7 (plan M4:
					// 68040.library probes them); M68040UM 3.1, PRM MOVEC 4-138
					12'h003: d.imm[3:0] = CR_TC;
					12'h004: d.imm[3:0] = CR_ITT0;
					12'h005: d.imm[3:0] = CR_ITT1;
					12'h006: d.imm[3:0] = CR_DTT0;
					12'h007: d.imm[3:0] = CR_DTT1;
					12'h805: d.imm[3:0] = CR_MMUSR;
					12'h806: d.imm[3:0] = CR_URP;
					12'h807: d.imm[3:0] = CR_SRP;
					default: d.imm[3:0] = CR_BAD;
				endcase
				d.imm[4] = op[0];                // 1 = Rn -> Rc
				d.src = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
				// an unknown selector is illegal -- in supervisor mode; MOVEC is
				// privileged first (user mode: vector 8 for every selector,
				// cputest MOVEC2; EA-fetch checks priv before CL_EXC)
				if (d.imm[3:0] == CR_BAD) begin
					d.cls = CL_EXC; d.exc_vec = 8'd4;
				end
			end
			F_CINV: begin d.cls = CL_NOP; d.priv = 1'b1; d.serialize = 1'b1; end
			F_MOVES: begin                      // a MOVE in the SFC/DFC space, no flags (PRM 6-24)
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE; d.priv = 1'b1; d.serialize = 1'b1;
				if (x1[11]) begin                 // Rn -> <ea> [DFC]
					d.src = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
					d.fcsel = 2'd2;
				end else begin                    // <ea> [SFC] -> Rn (An: sign-extended)
					d.src = d.dst;
					d.dst = ea_reg(x1[15] ? EK_AREG : EK_DREG, {1'b0, x1[15], x1[14:12]});
					d.fcsel = 2'd1;
				end
			end
			F_MOVEUSP: begin                    // as MOVEC USP (PRM MOVE USP 6-21: privileged)
				d.cls = CL_MOVEC; d.priv = 1'b1; d.serialize = 1'b1;
				d.imm[3:0] = CR_USP; d.imm[4] = !op[3];
				d.src = ea_reg(EK_AREG, {2'b01, op[2:0]});
			end
			F_NOP: d.cls = CL_NOP;   // (waits for posted stores in EA-fetch: sync_busy)
			F_RTE: begin d.cls = CL_RTE; d.priv = 1'b1; d.serialize = 1'b1; end
			default: ;
		endcase
	end
	// Branches to an odd address take the address error here, before any
	// part of them executes: Bcc whether or not the condition holds, BSR
	// before its push, DBcc before the condition and the decrement
	// (M68040UM 8.2.2, p. 8-8: "This includes the case of a conditional
	// branch instruction with an odd branch offset that is not taken";
	// reference ap040_core.v finish_bcc / S_BCC_EXT / S_DBCC1).  Format $2,
	// stacked PC = the branch, address = the target with A0 cleared.
	if ((d.cls == CL_BCC || d.cls == CL_BSR || d.cls == CL_DBCC) && d.btarget[0]) begin
		d.cls = CL_EXC; d.exc_vec = 8'd3; d.exc_fmt = 4'd2; d.exc_next = 1'b0;
		d.exc_addr = {d.btarget[31:1], 1'b0};
		d.dst = '0; d.dst.idx_reg = R_NONE; d.dst.reg_n = R_NONE;
	end
	// an illegal instruction is one word long for PC purposes
	if (d.cls == CL_EXC && !d.exc_next && d.exc_fmt == 4'd0) d.next_pc = vpc + 32'd2;
	if (d.cls == CL_EXC) d.serialize = 1'b1;
	d.size2 = s2set ? s2 : d.size;
	return d;
endfunction

wire id_t d = decf(vbuf, vpc, sh, tot, ln.ea_bad);

// the code gathered here (self-modifying-code check in the core)
assign g_lo = g_pc;
assign g_hi = g_pc + {27'd0, wcnt, 1'b0};
assign g_v  = (wcnt != 4'd0);

//--------------------------------------------------------------- emit

wire emit = complete && !flush && !stall_in;

// words taken: on emit, only this instruction's (the next one's first word
// may be the second word offered); while gathering, all of them; nothing
// while EA-calc is stalled
wire [4:0] need = tot - {1'b0, wcnt};
assign consume = (flush || stall_in) ? 2'd0 :
                 complete ? need[1:0] : avail;

// guess taken: Bcc/BRA/BSR redirect IF the clock they are emitted
assign id_redirect_valid = emit && (d.cls == CL_BCC || d.cls == CL_BSR || d.cls == CL_DBCC);
assign id_redirect_pc    = d.btarget;

always @(posedge clk) begin
	if (!nreset) begin
		id_valid <= 1'b0;
		id_o     <= '0;
		wbuf     <= '0;
		wcnt     <= 4'd0;
		g_pc     <= 32'd0;
	end else if (ce) begin
		if (flush) begin
			id_valid <= 1'b0;
			wcnt     <= 4'd0;
		end else if (!stall_in) begin
			if (complete) begin
				id_valid <= 1'b1;
				id_o     <= d;
				wcnt     <= 4'd0;
			end else begin
				id_valid <= 1'b0;
				if (avail != 2'd0) begin
					wbuf <= vbuf;
					if (wcnt == 4'd0) g_pc <= q_pc0;
					wcnt <= vcnt;
				end
			end
		end
	end
end

endmodule
