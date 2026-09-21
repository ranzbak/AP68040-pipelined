//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_core.v - top level (rewritten for Minimig plan M1)            //
//                                                                          //
//   IF -> ID -> EA-calc -> EA-fetch -> EX -> WB                            //
//                                                                          //
// WB is the commit point: the EX output register (exe_o, wb_t) is applied  //
// at the end of its clock -- register writes (three ports), CCR/SR,        //
// control registers, and the store (L1 port W).  Everything before WB is  //
// speculative and is thrown away by EX's redirect (flush of IF, ID,        //
// EA-calc, EA-fetch).  ap040_writeback.v is a one-clock-later valid/pc     //
// copy of retiring instructions, for the benches' debug taps.              //
//                                                                          //
// Parameters:                                                              //
//   PC_RESET, PROG_WORDS, L1_AW   as the milestone benches use them        //
//   RESET_FROM_VECTORS = 1: at reset EA-fetch loads ISP from (0) and PC    //
//     from (4) and IF starts there (the 68040).  0: IF starts at PC_RESET  //
//     with ISP = 0 (the milestone benches, which poke ISP).                //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_core
	import ap040_pipe_pkg::*;
#(
	parameter [31:0] PC_RESET           = 32'h0000_0400,
	parameter         PROG_WORDS         = 10,
	parameter         L1_AW              = 12,
	parameter         RESET_FROM_VECTORS = 0
)
(
	input  clk,
	input  nreset,
	input  ce,

	output        dbg_if_valid,  output [31:0] dbg_if_pc,
	output        dbg_id_valid,  output [31:0] dbg_id_pc,
	output        dbg_eac_valid, output [31:0] dbg_eac_pc,
	output        dbg_eaf_valid, output [31:0] dbg_eaf_pc,
	output        dbg_ex_valid,  output [31:0] dbg_ex_pc,
	output        dbg_wb_valid,  output [31:0] dbg_wb_pc,
	output [31:0] dbg_d0, output [31:0] dbg_d1, output [31:0] dbg_d2, output [31:0] dbg_d3,
	output [31:0] dbg_d4, output [31:0] dbg_d5, output [31:0] dbg_d6, output [31:0] dbg_d7,
	output  [4:0] dbg_ccr,
	output [15:0] dbg_sr
);

//--------------------------------------------------------------- stage wires
wire        q_v0, q_v1;  wire [31:0] q_pc0;  wire [15:0] q_w0, q_w1;  wire [1:0] id_consume;
wire        id_valid;  id_t id_o;
wire        eac_valid; eac_t eac_o;
wire        eaf_valid; ex_t eaf_o;
wire        exe_valid; wb_t exe_o;
wire        wb_valid;  wire [31:0] wb_pc;

wire ea_stall, eaf_stall, ex_stall;
wire eaf_blk, eaf_halted;

wire        id_redirect_valid;
wire [31:0] id_redirect_pc;
wire        ex_redirect;
wire [31:0] ex_redirect_pc;
wire        eac_redir_v, eaf_redir_v;
wire [31:0] eac_redir_pc, eaf_redir_pc;
// Redirects, oldest first: EX (not-taken branch, RTE, MOVE to SR, exception
// entry), EA-fetch (RTS, memory-indirect JMP/JSR), EA-calc (JMP/JSR), ID
// (guessed-taken Bcc/BSR/DBcc).  Each flushes the stages in front of it.
wire flush     = ex_redirect;                                   // EA-fetch
wire flush_eac = ex_redirect || eaf_redir_v;                    // EA-calc
wire flush_id  = ex_redirect || eaf_redir_v || eac_redir_v;     // ID
wire        redirect_valid = ex_redirect || eaf_redir_v || eac_redir_v || id_redirect_valid;
wire [31:0] redirect_pc    = ex_redirect ? ex_redirect_pc :
                             eaf_redir_v ? eaf_redir_pc :
                             eac_redir_v ? eac_redir_pc : id_redirect_pc;

//--------------------------------------------------------------- commit (WB)
wire commit = exe_valid;

reg [15:0] sr;
reg [31:0] vbr;
reg  [2:0] sfc, dfc;
reg [31:0] cacr;

always @(posedge clk) begin
	if (!nreset) begin
		sr   <= `AP040_SR_RESET;
		vbr  <= 32'h0;
		sfc  <= 3'h0;
		dfc  <= 3'h0;
		cacr <= 32'h0;
	end else if (ce && commit) begin
		if (exe_o.sr_v)       sr <= exe_o.sr_val;
		else if (exe_o.ccr_v) sr[4:0] <= exe_o.ccr_val;
		if (exe_o.creg_v) begin
			case (exe_o.creg_sel)
				CR_SFC:  sfc  <= exe_o.creg_val[2:0];
				CR_DFC:  dfc  <= exe_o.creg_val[2:0];
				CR_CACR: cacr <= exe_o.creg_val & 32'h8000_8000;
				CR_VBR:  vbr  <= exe_o.creg_val;
				default: ;
			endcase
		end
	end
end

// the SR as the stages in front see it: WB's commit written through
wire [15:0] sr_now = (commit && exe_o.sr_v)  ? exe_o.sr_val :
                     (commit && exe_o.ccr_v) ? {sr[15:5], exe_o.ccr_val} : sr;

assign dbg_ccr = sr[4:0];
assign dbg_sr  = sr;

//--------------------------------------------------------------- register file
wire [4:0]  ra_sb, ra_si, ra_db, ra_di, ra_a, ra_b;
wire [31:0] rd_sb, rd_si, rd_db, rd_di, rd_a, rd_b;
wire [31:0] usp_q, isp_q, msp_q;

ap040_pipe_regfile u_regfile
(
	.clk(clk), .ce(ce), .nreset(nreset),
	.w0_we(commit && exe_o.w0_v), .w0_r(exe_o.w0_r), .w0_d(exe_o.w0_val),
	.u1_we(commit && exe_o.u1_v), .u1_r(exe_o.u1_r), .u1_d(exe_o.u1_val),
	.u0_we(commit && exe_o.u0_v), .u0_r(exe_o.u0_r), .u0_d(exe_o.u0_val),
	.ra0(ra_sb), .ra1(ra_si), .ra2(ra_db), .ra3(ra_di), .ra4(ra_a), .ra5(ra_b),
	.rd0(rd_sb), .rd1(rd_si), .rd2(rd_db), .rd3(rd_di), .rd4(rd_a), .rd5(rd_b),
	.usp_q(usp_q), .isp_q(isp_q), .msp_q(msp_q),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7)
);

//--------------------------------------------------------------- memory
wire [L1_AW-1:0] l1_addr_a;
wire             l1_en_a;
wire      [31:0] l1_rdata_a;
wire             d_rd_req, d_rd_ack;
wire      [31:0] d_rd_addr, d_rd_data;
wire       [1:0] d_rd_size;
wire             d_wr_ready;

ap040_pipe_l1 #(
	.AW(L1_AW), .DW(16), .PC_RESET(PC_RESET)
) u_l1
(
	.clock     (clk),
	.nreset    (nreset),
	.address_a (l1_addr_a),
	.en_a      (l1_en_a),
	.q_a       (l1_rdata_a),
	.rd_req    (d_rd_req),
	.rd_addr   (d_rd_addr),
	.rd_size   (d_rd_size),
	.rd_ack    (d_rd_ack),
	.rd_data   (d_rd_data),
	.wr_req    (ce && commit && exe_o.st_v),
	.wr_addr   (exe_o.st_addr),
	.wr_size   (exe_o.st_size),
	.wr_data   (exe_o.st_data),
	.wr_ready  (d_wr_ready)
);

//--------------------------------------------------------------- stages
ap040_inst_fetch #(
	.PC_RESET(PC_RESET), .PROG_WORDS(PROG_WORDS), .L1_AW(L1_AW),
	.FETCH_AT_RESET(RESET_FROM_VECTORS ? 0 : 1)
) u_if
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
	.consume(id_consume),
	.l1_addr_a(l1_addr_a), .l1_en_a(l1_en_a), .l1_rdata_a(l1_rdata_a),
	.q_v0(q_v0), .q_v1(q_v1), .q_pc0(q_pc0), .q_w0(q_w0), .q_w1(q_w1)
);

ap040_decode u_id
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(ea_stall), .flush(flush_id),
	.q_v0(q_v0), .q_v1(q_v1), .q_pc0(q_pc0), .q_w0(q_w0), .q_w1(q_w1),
	.consume(id_consume),
	.id_redirect_valid(id_redirect_valid), .id_redirect_pc(id_redirect_pc),
	.id_valid(id_valid), .id_o(id_o)
);

wire older_busy  = eaf_valid || exe_valid;
wire older_store = eaf_valid && (eaf_o.st_v || eaf_o.dk == DK_MEM ||
                                 eaf_o.cls == CL_BSR || eaf_o.cls == CL_JSR);
wire    early_v;
rdreq_t early_rd;

// EX-stage pending writes for EA-calc
wire        fw_w0_v;
wire  [4:0] fw_w0_r;
wire [31:0] fw_w0_val;
wire        fw_ccr_v;
wire  [4:0] fw_ccr;
wire        fw_st_v;
wire [31:0] fw_st_addr, fw_st_data;
wire  [1:0] fw_st_size;
wire ex_w0_pend = eaf_valid && (eaf_o.dk == DK_REG || eaf_o.cls == CL_DBCC || eaf_o.cls == CL_SCC);

ap040_ea_calc u_eac
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(eaf_stall), .flush(flush_eac),
	.id_valid(id_valid), .id_i(id_o),
	.sr_in(sr_now),
	.ra_sb(ra_sb), .ra_si(ra_si), .ra_db(ra_db), .ra_di(ra_di),
	.rd_sb(rd_sb), .rd_si(rd_si), .rd_db(rd_db), .rd_di(rd_di),
	.p_eaf_v(eac_valid), .p_eaf(eac_o), .p_eaf_blk(eaf_blk),
	.p_ex_v(eaf_valid),
	.p_ex_w0_v(ex_w0_pend), .p_ex_w0_r(eaf_o.dr),
	.p_ex_u0_v(eaf_o.u0_v || eaf_o.sp_v), .p_ex_u0_r(eaf_o.sp_v ? eaf_o.sp_r : eaf_o.u0_r),
	.p_ex_u0_val(eaf_o.sp_v ? eaf_o.sp_val : eaf_o.u0_val),
	.p_ex_u1_v(eaf_o.u1_v), .p_ex_u1_r(eaf_o.u1_r), .p_ex_u1_val(eaf_o.u1_val),
	.p_ex_store(older_store),
	.ea_stall(ea_stall),
	.early_v(early_v), .early(early_rd),
	.eac_redir_v(eac_redir_v), .eac_redir_pc(eac_redir_pc),
	.eac_valid(eac_valid), .eac_o(eac_o)
);



ap040_ea_fetch u_eaf
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(ex_stall), .flush(flush),
	.eac_valid(eac_valid), .eac_i(eac_o),
	.sr_in(sr_now), .vbr_in(vbr),
	.older_busy(older_busy), .older_store(older_store),
	.reset_seq(RESET_FROM_VECTORS != 0),
	.early_v(early_v), .early(early_rd),
	.ra_a(ra_a), .ra_b(ra_b), .rd_a(rd_a), .rd_b(rd_b),
	.ex_w0_v(fw_w0_v), .ex_w0_r(fw_w0_r), .ex_w0_val(fw_w0_val),
	.ex_u0_v(eaf_valid && (eaf_o.u0_v || eaf_o.sp_v)), .ex_u0_r(eaf_o.sp_v ? eaf_o.sp_r : eaf_o.u0_r),
	.ex_u0_val(eaf_o.sp_v ? eaf_o.sp_val : eaf_o.u0_val),
	.ex_u1_v(eaf_valid && eaf_o.u1_v), .ex_u1_r(eaf_o.u1_r), .ex_u1_val(eaf_o.u1_val),
	.ex_ccr_v(fw_ccr_v), .ex_ccr(fw_ccr),
	.rd_req(d_rd_req), .rd_addr(d_rd_addr), .rd_size(d_rd_size),
	.rd_ack(d_rd_ack), .rd_data_raw(d_rd_data),
	.wb_st_v(commit && exe_o.st_v), .wb_st_addr(exe_o.st_addr), .wb_st_size(exe_o.st_size), .wb_st_data(exe_o.st_data),
	.ex_st_v(fw_st_v), .ex_st_addr(fw_st_addr), .ex_st_size(fw_st_size), .ex_st_data(fw_st_data),
	.eaf_stall(eaf_stall), .eaf_blk(eaf_blk),
	.eaf_valid(eaf_valid), .eaf_o(eaf_o),
	.halted(eaf_halted),
	.eaf_redir_v(eaf_redir_v), .eaf_redir_pc(eaf_redir_pc)
);

ap040_execute u_ex
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(1'b0),
	.eaf_valid(eaf_valid), .x(eaf_o),
	.ccr_in(sr_now[4:0]), .sr_in(sr_now),
	.sfc_in({29'd0, sfc}), .dfc_in({29'd0, dfc}), .cacr_in(cacr), .vbr_in(vbr),
	.ex_stall(ex_stall),
	.fw_w0_v(fw_w0_v), .fw_w0_r(fw_w0_r), .fw_w0_val(fw_w0_val),
	.fw_ccr_v(fw_ccr_v), .fw_ccr(fw_ccr),
	.fw_st_v(fw_st_v), .fw_st_addr(fw_st_addr), .fw_st_size(fw_st_size), .fw_st_data(fw_st_data),
	.ex_redirect(ex_redirect), .ex_redirect_pc(ex_redirect_pc),
	.exe_valid(exe_valid), .exe_o(exe_o)
);

ap040_writeback u_wb
(
	.clk(clk), .nreset(nreset), .ce(ce), .stall_in(1'b0),
	.exe_valid(exe_valid && exe_o.last), .exe_pc(exe_o.pc),
	.wb_stall(), .wb_valid(wb_valid), .wb_pc(wb_pc)
);

assign dbg_if_valid  = q_v0;      assign dbg_if_pc  = q_pc0;
assign dbg_id_valid  = id_valid;  assign dbg_id_pc  = id_o.pc;
assign dbg_eac_valid = eac_valid; assign dbg_eac_pc = eac_o.i.pc;
assign dbg_eaf_valid = eaf_valid; assign dbg_eaf_pc = eaf_o.pc;
assign dbg_ex_valid  = exe_valid; assign dbg_ex_pc  = exe_o.pc;
assign dbg_wb_valid  = wb_valid;  assign dbg_wb_pc  = wb_pc;

endmodule
