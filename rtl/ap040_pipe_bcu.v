//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_bcu.v - bus controller: one memory port for IF, EA-fetch and  //
// the stores WB commits (Minimig plan M5)                                  //
//                                                                          //
// Memory side: the reference core's request port (lib/AP68040 ap040_core.v //
// mem_*): mem_req with {write, instr, size, addr, wdata, fc} held stable   //
// until mem_ack (a one-clock pulse, mem_rdata valid with it); mem_req is   //
// dropped in the ack clock, so it is low at the next enabled edge before  //
// a new request ("Changing an address while req remains asserted can make  //
// a completed request look like a duplicate transaction", ap040_core.v    //
// S_EPF_GAP).  Everything runs on the core's clock enable (the Minimig    //
// kernel is gated by clkena, ap040_tg68k_compat.v).                        //
//                                                                          //
// Clients:                                                                 //
//   stores  WB's committed store enters a posted-store FIFO (SB_N deep);   //
//           sb_full makes WB hold the store.  Stores go first: they are    //
//           older than any read outstanding.                               //
//   data    EA-fetch's read (rd_req a one-clock pulse, one outstanding),   //
//           answered by rd_ack.  It waits until every older store is in   //
//           memory: none in the FIFO, none committing in WB, none in EX    //
//           (older_st) -- so a read never needs store forwarding here.     //
//   fetch   IF's request (f_req held until f_gnt), answered by f_ack.      //
//           Lowest priority.                                               //
//                                                                          //
// mem_flt (an access error, M6) ends the transfer like an ack; rd_err /    //
// f_err flag the answer.  A store's error is fatal (st_err: nothing can be //
// restarted -- the reference's post_err).                                  //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_pipe_bcu
	import ap040_pipe_pkg::*;
#(
	parameter SB_N = 4
)
(
	input             clk,
	input             nreset,
	input             ce,

	// stores (WB commit)
	input             st_v,       // commits this clock
	input      [31:0] st_addr,
	input       [1:0] st_size,
	input      [31:0] st_data,
	input       [2:0] st_fc,
	input             st_rb,      // (a CAS/CAS2 locked write-back: carried to mem_rb for the benches)
	output            sb_full,    // WB must hold a store
	output            sb_busy,    // a posted store is not in memory yet
	input             older_st,   // EX or WB holds a store not yet committed

	// data reads (EA-fetch)
	input             rd_req,
	input      [31:0] rd_addr,
	input       [1:0] rd_size,
	input       [2:0] rd_fc,
	output reg        rd_ack,
	output reg [31:0] rd_data,
	output reg        rd_err,

	// instruction fetch (IF)
	input             f_req,
	input      [31:0] f_addr,
	input             f_long,
	input       [2:0] f_fc,
	output            f_gnt,
	output reg        f_ack,
	output reg [31:0] f_data,
	output reg        f_err,

	output reg        st_err,

	// memory port
	output reg        mem_req,
	output reg        mem_write,
	output reg        mem_instr,
	output reg  [1:0] mem_size,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg  [2:0] mem_fc,
	output reg        mem_rb,     // the store in progress is a locked write-back (debug)
	input             mem_ack,
	input      [31:0] mem_rdata,
	input             mem_flt,
	input             mem_atc,    // (with mem_flt) the MMU's fault, not the bus's (M7)
	output reg        rd_atc,
	output reg        f_atc
);

//--------------------------------------------------------------- store FIFO
localparam PW = (SB_N <= 2) ? 1 : (SB_N <= 4) ? 2 : 3;
reg [31:0] sb_a [0:SB_N-1];
reg [31:0] sb_d [0:SB_N-1];
reg  [1:0] sb_s [0:SB_N-1];
reg  [2:0] sb_f [0:SB_N-1];
reg        sb_b [0:SB_N-1];
reg [PW-1:0] sb_rp, sb_wp;
reg [PW:0]   sb_cnt;

assign sb_full = (sb_cnt == SB_N[PW:0]);
assign sb_busy = (sb_cnt != 0) || (mem_req && mem_write);

//--------------------------------------------------------------- data read slot
reg        dq_v;
reg [31:0] dq_a;
reg  [1:0] dq_s;
reg  [2:0] dq_f;

//--------------------------------------------------------------- the port
localparam [1:0] K_ST = 2'd0, K_RD = 2'd1, K_IF = 2'd2;
reg  [1:0] kind;           // what the transfer in progress is

wire idle    = !mem_req;         // (a new request never starts in the ack clock: one low enabled edge)
wire go_st   = idle && (sb_cnt != 0);
// A read goes from the slot, never in the clock it is requested: EA-fetch
// may be sending the older instruction's store to EX in that same clock
// (an early read), and older_st sees it only once it is there.
wire go_rd   = idle && (sb_cnt == 0) && !st_v && !older_st && dq_v;
wire go_if   = idle && !go_st && !go_rd && f_req;
assign f_gnt = go_if;

wire done    = mem_req && (mem_ack || mem_flt);

integer k;
always @(posedge clk) begin
	if (!nreset) begin
		mem_req <= 1'b0; mem_write <= 1'b0; mem_instr <= 1'b0; mem_size <= SZ_L;
		mem_addr <= 32'd0; mem_wdata <= 32'd0; mem_fc <= 3'd5;
		kind <= K_ST;
		sb_rp <= '0; sb_wp <= '0; sb_cnt <= '0;
		dq_v <= 1'b0; dq_a <= 32'd0; dq_s <= SZ_L; dq_f <= 3'd5;
		rd_ack <= 1'b0; rd_data <= 32'd0; rd_err <= 1'b0; rd_atc <= 1'b0; f_atc <= 1'b0;
		f_ack <= 1'b0; f_data <= 32'd0; f_err <= 1'b0;
		st_err <= 1'b0;
		for (k = 0; k < SB_N; k = k + 1) begin sb_a[k] <= 32'd0; sb_d[k] <= 32'd0; sb_s[k] <= SZ_L; sb_f[k] <= 3'd5; sb_b[k] <= 1'b0; end
		mem_rb <= 1'b0;
	end else if (ce) begin
		rd_ack <= 1'b0; f_ack <= 1'b0;
		// a store committed by WB
		if (st_v) begin
			sb_a[sb_wp] <= st_addr; sb_d[sb_wp] <= st_data; sb_s[sb_wp] <= st_size; sb_f[sb_wp] <= st_fc;
			sb_b[sb_wp] <= st_rb;
			sb_wp <= sb_wp + 1'b1;
		end
		sb_cnt <= sb_cnt + (st_v ? 1'b1 : 1'b0) - ((done && kind == K_ST) ? 1'b1 : 1'b0);
		// a data read request waits in the slot
		if (rd_req) begin dq_v <= 1'b1; dq_a <= rd_addr; dq_s <= rd_size; dq_f <= rd_fc; end
		// completion
		if (done) begin
			mem_req <= 1'b0;
			case (kind)
				K_ST: begin
					sb_rp <= sb_rp + 1'b1;
					if (mem_flt) st_err <= 1'b1;
				end
				K_RD: begin rd_ack <= 1'b1; rd_data <= mem_rdata; rd_err <= mem_flt; rd_atc <= mem_flt && mem_atc; end
				default: begin                // a word fetch answers right-aligned: IF wants it on top
					f_ack <= 1'b1; f_err <= mem_flt; f_atc <= mem_flt && mem_atc;
					f_data <= (mem_size == SZ_W) ? {mem_rdata[15:0], 16'h4E71} : mem_rdata;
				end
			endcase
		end
		// a new transfer
		if (go_st) begin
			mem_req <= 1'b1; kind <= K_ST; mem_write <= 1'b1; mem_instr <= 1'b0;
			mem_addr <= sb_a[sb_rp]; mem_size <= sb_s[sb_rp]; mem_wdata <= sb_d[sb_rp]; mem_fc <= sb_f[sb_rp];
			mem_rb <= sb_b[sb_rp];
		end else if (go_rd) begin
			mem_req <= 1'b1; kind <= K_RD; mem_write <= 1'b0; mem_instr <= 1'b0;
			mem_addr <= dq_a; mem_size <= dq_s; mem_fc <= dq_f;
			dq_v <= 1'b0;
		end else if (go_if) begin
			mem_req <= 1'b1; kind <= K_IF; mem_write <= 1'b0; mem_instr <= 1'b1;
			mem_addr <= f_addr; mem_size <= f_long ? SZ_L : SZ_W; mem_fc <= f_fc;
		end
	end
end

endmodule
