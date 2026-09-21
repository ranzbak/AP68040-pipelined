//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_execute.v - EX stage (rewritten for Minimig plan M1)               //
//                                                                          //
// One micro-op per clock.  Computes the ALU result and flags, merges a     //
// byte/word result into its Dn, sign-extends a MOVEA.W, resolves branches  //
// (ID guessed taken: a not-taken Bcc/DBcc redirects to next_pc), and      //
// redirects for JMP/JSR/RTS/RTE/MOVE-to-SR/exception entry.  The redirect  //
// flushes IF/ID/EA-calc/EA-fetch.  Results go to the WB register (wb_t);  //
// WB commits them at the end of its clock.                                 //
//                                                                          //
// Forwarding: the result register value (w0) and the An updates of the    //
// micro-op in this stage are offered to EA-fetch combinationally.          //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_execute
	import ap040_pipe_pkg::*;
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // WB cannot accept

	input             eaf_valid,
	input  ex_t       x,

	input       [4:0] ccr_in,     // CCR with the WB write-through
	input      [31:0] sfc_in, dfc_in, cacr_in, vbr_in,

	output            ex_stall,

	// forwarding
	output            fw_w0_v,
	output      [4:0] fw_w0_r,
	output     [31:0] fw_w0_val,

	output            fw_ccr_v,
	output      [4:0] fw_ccr,

	output            ex_redirect,
	output     [31:0] ex_redirect_pc,

	output reg        exe_valid,
	output wb_t       exe_o
);

assign ex_stall = stall_in;

wire [31:0] alu_result;
wire  [4:0] alu_flags;

ap040_pipe_alu alu
(
	.op        (x.alu),
	.size      (x.size),
	.shcnt     (6'd1),
	.a         (x.a),
	.b         (x.b),
	.flags_in  (ccr_in),
	.result    (alu_result),
	.flags_out (alu_flags)
);

wire cond = cond_true(x.cond, ccr_in);

// DBcc
wire [15:0] dbcc_dec   = x.b[15:0] - 16'd1;
wire        dbcc_taken = !cond && (dbcc_dec != 16'hFFFF);

function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] v, input logic [1:0] sz);
	case (sz)
		SZ_B:    return {old[31:8], v[7:0]};
		SZ_W:    return {old[31:16], v[15:0]};
		default: return v;
	endcase
endfunction

logic [31:0] creg_rd;
always @* begin
	case (x.creg_sel)
		CR_SFC:  creg_rd = sfc_in;
		CR_DFC:  creg_rd = dfc_in;
		CR_CACR: creg_rd = cacr_in;
		CR_VBR:  creg_rd = vbr_in;
		default: creg_rd = x.a;          // USP/ISP/MSP: EA-fetch read the register
	endcase
end

wb_t w;
logic redir;
logic [31:0] redir_pc;
always @* begin
	w = '0;
	w.pc = x.pc; w.last = x.last;
	w.w0_r = R_NONE; w.u0_r = R_NONE; w.u1_r = R_NONE;
	w.u0_v = x.u0_v; w.u0_r = x.u0_r; w.u0_val = x.u0_val;
	w.u1_v = x.u1_v; w.u1_r = x.u1_r; w.u1_val = x.u1_val;
	w.st_v = x.st_v; w.st_addr = x.st_addr; w.st_data = x.st_data; w.st_size = x.st_size;
	w.sr_v = x.sr_v; w.sr_val = x.sr_val;
	w.exc  = x.exc;  w.exc_sp = x.sp_val;
	// a sequenced stack-pointer write goes out on the u0 port
	if (x.sp_v) begin w.u0_v = 1'b1; w.u0_r = x.sp_r; w.u0_val = x.sp_val; end
	redir = x.redirect; redir_pc = x.target;
	case (x.cls)
		CL_ALU: begin
			w.ccr_v = x.wr_ccr; w.ccr_val = alu_flags;
			if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr;
				if (x.dr[4:3] == 2'b00) w.w0_val = merge(x.b, alu_result, x.size);   // Dn
				else w.w0_val = (x.size == SZ_W) ? sext16(x.a[15:0]) : x.a;       // MOVEA
			end else if (x.dk == DK_MEM) begin
				w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = alu_result; w.st_size = x.size;
			end
		end
		CL_BCC: begin
			redir = 1'b0;            // resolved (and redirected) in EA-fetch
		end
		CL_BSR, CL_JSR: begin
			w.st_v = 1'b1; w.st_addr = x.daddr; w.st_data = x.next_pc; w.st_size = SZ_L;
		end
		CL_DBCC: begin               // the branch was resolved in EA-fetch; EX decrements
			if (!x.cc) begin w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = {x.b[31:16], dbcc_dec}; end
			redir = 1'b0;
		end
		CL_SCC: begin
			w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = {x.b[31:8], {8{cond}}};
		end
		CL_MOVE2SR: begin
			w.sr_v = 1'b1; w.sr_val = x.a[15:0] & `AP040_SR_MASK;
		end
		CL_MOVEC: begin
			if (!x.creg_to) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = creg_rd;
			end else if (x.dk == DK_REG) begin
				w.w0_v = 1'b1; w.w0_r = x.dr; w.w0_val = x.a;     // Rn -> USP/ISP/MSP
			end else begin
				w.creg_v = 1'b1; w.creg_sel = x.creg_sel; w.creg_val = x.a;
			end
		end
		default: ;
	endcase
end

// the CCR this micro-op leaves, for EA-fetch's branch resolution
assign fw_ccr_v  = eaf_valid && (w.ccr_v || w.sr_v);
assign fw_ccr    = w.sr_v ? w.sr_val[4:0] : w.ccr_val;

assign fw_w0_v   = eaf_valid && w.w0_v;
assign fw_w0_r   = w.w0_r;
assign fw_w0_val = w.w0_val;

assign ex_redirect    = eaf_valid && redir;
assign ex_redirect_pc = redir_pc;

always @(posedge clk) begin
	if (!nreset) begin
		exe_valid <= 1'b0;
		exe_o     <= '0;
	end else if (ce && !stall_in) begin
		exe_valid <= eaf_valid;
		if (eaf_valid) exe_o <= w;
	end
end

endmodule
