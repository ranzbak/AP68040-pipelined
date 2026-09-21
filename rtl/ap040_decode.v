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
	output id_t       id_o
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

// What an opcode word implies about the words that follow it.
typedef struct packed {
	logic       ok;        // implemented and legal as far as the opcode word says
	logic [1:0] npre;      // words before the EAs
	logic       has_src;
	logic [2:0] sm, sr;    // source EA mode/reg
	logic       has_dst;
	logic [2:0] dm, dr;    // destination EA mode/reg
	logic [1:0] sz;        // operand size (sizes #imm and the EA length)
} shape_t;

function automatic shape_t shape(input logic [15:0] op);
	shape_t s;
	s = '0;
	s.sm = op[5:3]; s.sr = op[2:0];
	s.sz = SZ_L;
	casez (op)
		// MOVE / MOVEA: 00ss RRRM MMrr rrrr, ss = 01 B, 11 W, 10 L
		16'b0001_????_????_????, 16'b0010_????_????_????, 16'b0011_????_????_????: begin
			s.sz = (op[13:12] == 2'b01) ? SZ_B : (op[13:12] == 2'b11) ? SZ_W : SZ_L;
			s.has_src = 1'b1; s.has_dst = 1'b1;
			s.dm = op[8:6]; s.dr = op[11:9];
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b0, 1'b0) &&
			       !(s.sz == SZ_B && s.sm == 3'd1) &&
			       ((s.dm == 3'd1) ? (s.sz != SZ_B) : ea_ok(s.dm, s.dr, 1'b1, 1'b0, 1'b0, 1'b1));
		end
		// MOVEQ
		16'b0111_???0_????_????: s.ok = 1'b1;
		// ADD.L Dn,Dm (the milestone-2 form; the full ADD family is M2)
		16'b1101_???0_1000_0???: s.ok = 1'b1;
		// Bcc / BRA / BSR
		16'b0110_????_????_????: begin
			s.ok = 1'b1;
			s.npre = (op[7:0] == 8'h00) ? 2'd1 : (op[7:0] == 8'hFF) ? 2'd2 : 2'd0;
		end
		// DBcc
		16'b0101_????_1100_1???: begin s.ok = 1'b1; s.npre = 2'd1; end
		// Scc Dn (all EAs in M2)
		16'b0101_????_1100_0???: s.ok = 1'b1;
		// JMP / JSR <control EA>
		16'b0100_1110_11??_????, 16'b0100_1110_10??_????: begin
			s.has_src = 1'b1;
			s.ok = ea_ok(s.sm, s.sr, 1'b0, 1'b0, 1'b1, 1'b0);
		end
		// TRAP #n
		16'b0100_1110_0100_????: s.ok = 1'b1;
		// MOVE <ea>,SR
		16'b0100_0110_11??_????: begin
			s.has_src = 1'b1; s.sz = SZ_W;
			s.ok = ea_ok(s.sm, s.sr, 1'b1, 1'b0, 1'b0, 1'b0);
		end
		// MOVEC
		16'b0100_1110_0111_101?: begin s.ok = 1'b1; s.npre = 2'd1; end
		16'h4E71, 16'h4E73, 16'h4E75: s.ok = 1'b1;   // NOP, RTE, RTS
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

function automatic id_t decf(input logic [10:0][15:0] vbuf, input logic [31:0] vpc,
                             input shape_t sh, input logic [4:0] tot_w, input logic ea_bad);
	id_t d;
	int tot;
	logic [15:0] op, x1;
	int ks, kd; elen_t e;
	tot = tot_w;
	op = vbuf[0];
	x1 = vbuf[1];
	d = '0;
	d.pc = vpc;
	d.next_pc = vpc + 32'(2 * tot);
	d.opcode = op;
	d.ext = x1;
	d.size = sh.sz;
	d.cond = op[11:8];
	d.src.idx_reg = R_NONE; d.dst.idx_reg = R_NONE;
	d.src.reg_n = R_NONE; d.dst.reg_n = R_NONE;
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
		casez (op)
			16'b0001_????_????_????, 16'b0010_????_????_????, 16'b0011_????_????_????: begin
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE;
				d.wr_ccr = (sh.dm != 3'd1);         // MOVEA leaves the CCR alone
			end
			16'b0111_???0_????_????: begin      // MOVEQ
				d.cls = CL_ALU; d.alu = `AP040_ALU_MOVE; d.size = SZ_L; d.wr_ccr = 1'b1;
				d.src = '0; d.src.kind = EK_IMM; d.src.bd = sext8(op[7:0]); d.src.idx_reg = R_NONE; d.src.reg_n = R_NONE;
				d.dst = '0; d.dst.kind = EK_DREG; d.dst.reg_n = {2'b00, op[11:9]}; d.dst.idx_reg = R_NONE;
			end
			16'b1101_???0_1000_0???: begin      // ADD.L Dn,Dm
				d.cls = CL_ALU; d.alu = `AP040_ALU_ADD; d.size = SZ_L; d.wr_ccr = 1'b1;
				d.src = '0; d.src.kind = EK_DREG; d.src.reg_n = {2'b00, op[2:0]}; d.src.idx_reg = R_NONE;
				d.dst = '0; d.dst.kind = EK_DREG; d.dst.reg_n = {2'b00, op[11:9]}; d.dst.idx_reg = R_NONE;
				d.rmw = 1'b1;
			end
			16'b0110_????_????_????: begin      // Bcc / BRA / BSR
				d.cls = (op[11:8] == 4'h1) ? CL_BSR : CL_BCC;
				d.btarget = vpc + 32'd2 + ((op[7:0] == 8'h00) ? sext16(x1) :
				                           (op[7:0] == 8'hFF) ? {x1, vbuf[2]} : sext8(op[7:0]));
				if (op[11:8] == 4'h1) begin      // BSR: the push is a store to -(A7)
					d.size = SZ_L;
					d.dst = '0; d.dst.kind = EK_MEM; d.dst.base_en = 1'b1; d.dst.reg_n = R_A7L;
					d.dst.upd = UPD_PRE; d.dst.idx_reg = R_NONE; d.dst.mode = 3'd4; d.dst.mreg = 3'd7;
				end
			end
			16'b0101_????_1100_1???: begin      // DBcc
				d.cls = CL_DBCC; d.size = SZ_W;
				d.dst = '0; d.dst.kind = EK_DREG; d.dst.reg_n = {2'b00, op[2:0]}; d.dst.idx_reg = R_NONE;
				d.btarget = vpc + 32'd2 + sext16(x1);
			end
			16'b0101_????_1100_0???: begin      // Scc Dn
				d.cls = CL_SCC; d.size = SZ_B;
				d.dst = '0; d.dst.kind = EK_DREG; d.dst.reg_n = {2'b00, op[2:0]}; d.dst.idx_reg = R_NONE;
			end
			16'b0100_1110_11??_????: begin d.cls = CL_JMP; d.size = SZ_L; end
			16'b0100_1110_10??_????: begin      // JSR: the push is a store to -(A7)
				d.cls = CL_JSR; d.size = SZ_L;
				d.dst = '0; d.dst.kind = EK_MEM; d.dst.base_en = 1'b1; d.dst.reg_n = R_A7L;
				d.dst.upd = UPD_PRE; d.dst.idx_reg = R_NONE; d.dst.mode = 3'd4; d.dst.mreg = 3'd7;
			end
			16'b0100_1110_0100_????: begin      // TRAP #n
				d.cls = CL_EXC; d.exc_vec = 8'd32 + {4'd0, op[3:0]}; d.exc_next = 1'b1;
			end
			16'b0100_0110_11??_????: begin      // MOVE <ea>,SR
				d.cls = CL_MOVE2SR; d.priv = 1'b1; d.serialize = 1'b1; d.size = SZ_W;
			end
			16'b0100_1110_0111_101?: begin      // MOVEC
				d.cls = CL_MOVEC; d.priv = 1'b1; d.serialize = 1'b1;
				case (x1[11:0])
					12'h000: d.imm[3:0] = CR_SFC;
					12'h001: d.imm[3:0] = CR_DFC;
					12'h002: d.imm[3:0] = CR_CACR;
					12'h801: d.imm[3:0] = CR_VBR;
					12'h800: d.imm[3:0] = CR_USP;
					12'h804: d.imm[3:0] = CR_ISP;
					12'h803: d.imm[3:0] = CR_MSP;
					default: d.imm[3:0] = CR_BAD;
				endcase
				d.imm[4] = op[0];                // 1 = Rn -> Rc
				d.src = '0; d.src.idx_reg = R_NONE;
				d.src.kind = x1[15] ? EK_AREG : EK_DREG;
				d.src.reg_n = {1'b0, x1[15], x1[14:12]};
				if (d.imm[3:0] == CR_BAD) begin
					d.cls = CL_EXC; d.exc_vec = 8'd4; d.priv = 1'b0;
				end
			end
			16'h4E71: d.cls = CL_NOP;
			16'h4E73: begin d.cls = CL_RTE; d.priv = 1'b1; d.serialize = 1'b1; end
			16'h4E75: begin                     // RTS: the pop is a load from (A7)+
				d.cls = CL_RTS; d.size = SZ_L;
				d.src = '0; d.src.kind = EK_MEM; d.src.base_en = 1'b1; d.src.reg_n = R_A7L;
				d.src.upd = UPD_POST; d.src.idx_reg = R_NONE; d.src.mode = 3'd3; d.src.mreg = 3'd7;
			end
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
	return d;
endfunction

wire id_t d = decf(vbuf, vpc, sh, tot, ln.ea_bad);

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
