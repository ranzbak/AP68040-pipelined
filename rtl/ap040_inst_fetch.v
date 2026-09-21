//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_inst_fetch.v - IF stage                                            //
//                                                                          //
// A PC register driving L1 port A; one 16-bit word per clock to ID.        //
// redirect_valid/redirect_pc select the next PC instead of +2.             //
//                                                                          //
// Minimig plan M1 changes:                                                 //
//  * ex_redirect (EX's flush) is taken even while ID is stalled.  Before,   //
//    a redirect arriving in a stalled clock was dropped and IF carried on   //
//    down the wrong path (found by the M0.5 cycle checker: back-to-back    //
//    JSRs with the write buffer busy).  ID's own redirect is only raised    //
//    when ID is not stalled, so it needs no such rule.                     //
//  * FETCH_AT_RESET = 0: IF stays idle after reset until the first         //
//    redirect (the reset vector fetch in EA-fetch supplies it).  1 keeps    //
//    the milestone benches' PC_RESET start.                               //
//                                                                          //
// PROG_WORDS still bounds how many words are issued (the milestone benches' //
// drain checks rely on it).                                                //
//--------------------------------------------------------------------------//

module ap040_inst_fetch
#(
	parameter [31:0] PC_RESET       = 32'h0000_0400,
	parameter         PROG_WORDS     = 10,
	parameter         L1_AW          = 12,
	parameter         FETCH_AT_RESET = 1
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,     // ID cannot accept a new word this cycle

	input             redirect_valid,
	input      [31:0] redirect_pc,
	input             ex_redirect,  // redirect_valid is EX's flush: honour it through a stall

	output [L1_AW-1:0] l1_addr_a,
	output             l1_en_a,
	input       [15:0] l1_rdata_a,

	output reg        if_valid,
	output reg [31:0] if_pc,
	output     [15:0] if_opcode
);

reg [31:0] pc;
reg [31:0] issued;
reg        running;
wire       have_more = (issued < PROG_WORDS) && (running || redirect_valid);

wire [31:0] fetch_pc = redirect_valid ? redirect_pc : pc;
wire        step     = ce && (!stall_in || ex_redirect);

assign l1_addr_a = (fetch_pc - PC_RESET) >> 1;
assign l1_en_a   = step;
assign if_opcode = l1_rdata_a;

always @(posedge clk) begin
	if (!nreset) begin
		pc        <= PC_RESET;
		issued    <= 32'd0;
		if_valid  <= 1'b0;
		if_pc     <= PC_RESET;
		running   <= (FETCH_AT_RESET != 0);
	end else if (step) begin
		if_valid <= have_more;
		if (redirect_valid) running <= 1'b1;
		if (have_more) begin
			if_pc     <= fetch_pc;
			pc        <= fetch_pc + 32'd2;
			issued    <= issued + 32'd1;
		end
	end
end

endmodule
