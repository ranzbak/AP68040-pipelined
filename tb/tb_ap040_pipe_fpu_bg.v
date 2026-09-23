//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// tb_ap040_pipe_fpu_bg.v - plan M10.1(c): the BACKGROUND release.          //
//                                                                          //
// The interlock's whole point is that a long floating-point operation is    //
// released at `accepted` -- the moment after which only completion or an    //
// enabled arithmetic exception can follow -- and the integer instructions   //
// behind it run while the unit finishes.  That is invisible to a program:   //
// the architectural result is the same either way, which is why fpustub.s   //
// cannot test it and this bench exists.                                     //
//                                                                          //
// The program is                                                            //
//     FMOVE.L D0,FP0 ; FMOVE.L D0,FP1 ; FADD.X FP1,FP0 ; 4 x ADDQ.L #1,D1   //
// with the stub unit's LAT_ARITH = 9.  The check is direct: instructions    //
// must RETIRE while `fp_bg` is set, i.e. while a released operation is      //
// still running.  A core that waited for `done` would retire none.          //
//                                                                          //
// It also checks the two things the release must not break: the ADDQs'      //
// result (D1 = 4, they really ran) and the operation's own result, read     //
// back afterwards (D2 = 12, the reader waited).                             //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_ap040_pipe_fpu_bg;

localparam PROG_WORDS      = 40;
localparam [31:0] PC_RESET = 32'h0000_0400;

reg clk = 0;
reg nreset = 0;
reg ce = 1;

always #5 clk = ~clk;

wire        dbg_wb_valid;
wire [31:0] dbg_wb_pc;
wire [31:0] dbg_d1, dbg_d2;

wire        fp_req, fp_done, fp_accepted, fp_unimp, fp_unsupp, fp_dbl;
wire  [2:0] fp_op_class, fp_src_fmt, fp_src_r, fp_dst_r;
wire  [6:0] fp_opmode;
wire [95:0] fp_din, fp_dout;

ap040_pipe_core #(
	.PC_RESET(PC_RESET), .PROG_WORDS(PROG_WORDS), .HAS_FPU(1)
) dut
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.dbg_wb_valid(dbg_wb_valid), .dbg_wb_pc(dbg_wb_pc),
	.dbg_d1(dbg_d1), .dbg_d2(dbg_d2),
	.fp_req(fp_req), .fp_op_class(fp_op_class), .fp_opmode(fp_opmode),
	.fp_src_fmt(fp_src_fmt), .fp_src_r(fp_src_r), .fp_dst_r(fp_dst_r), .fp_din(fp_din),
	.fp_done(fp_done), .fp_accepted(fp_accepted), .fp_unimp(fp_unimp), .fp_unsupp(fp_unsupp),
	.fp_dout(fp_dout)
);

tb_fpu_stub u_fpu
(
	.clk(clk), .nreset(nreset), .ce(ce),
	.req(fp_req), .op_class(fp_op_class), .opmode(fp_opmode),
	.src_fmt(fp_src_fmt), .src_r(fp_src_r), .dst_r(fp_dst_r), .din(fp_din),
	.done(fp_done), .accepted(fp_accepted), .unimp(fp_unimp), .unsupp(fp_unsupp),
	.dout(fp_dout), .dbl_req(fp_dbl)
);

integer errors    = 0;
integer bg_retire = 0;      // instructions retired while an operation was in flight

initial begin
	#1;
	dut.u_l1.mem[ 1] = 16'h7205;   // MOVEQ #5,D1       (the value loaded into FP0)
	dut.u_l1.mem[ 2] = 16'hF201;   // FMOVE.L D1,FP0
	dut.u_l1.mem[ 3] = 16'h4000;
	dut.u_l1.mem[ 4] = 16'h7207;   // MOVEQ #7,D1
	dut.u_l1.mem[ 5] = 16'hF201;   // FMOVE.L D1,FP1
	dut.u_l1.mem[ 6] = 16'h4080;
	dut.u_l1.mem[ 7] = 16'hF200;   // FADD.X FP1,FP0    -> FP0 = 12, a long operation
	dut.u_l1.mem[ 8] = 16'h0422;
	dut.u_l1.mem[ 9] = 16'h7200;   // MOVEQ #0,D1       ) these four must retire
	dut.u_l1.mem[10] = 16'h5281;   // ADDQ.L #1,D1      ) while the unit is still
	dut.u_l1.mem[11] = 16'h5281;   // ADDQ.L #1,D1      ) running: that is the
	dut.u_l1.mem[12] = 16'h5281;   // ADDQ.L #1,D1      ) background release
	dut.u_l1.mem[13] = 16'h5281;   // ADDQ.L #1,D1      -> D1 = 4
	dut.u_l1.mem[14] = 16'hF202;   // FMOVE.L FP0,D2    -> D2 = 12 (waits for done)
	dut.u_l1.mem[15] = 16'h6000;
end

// a retirement while a released operation is outstanding
always @(posedge clk)
	if (nreset && ce && dbg_wb_valid && dut.u_eaf.fp_bg)
		bg_retire = bg_retire + 1;

initial begin
	nreset = 0;
	repeat (2) @(posedge clk);
	nreset = 1;
	repeat (PROG_WORDS + 80) @(posedge clk);

	// The stub's FADD takes 9 clocks and is released after 2, so there are
	// about six clocks of background.  Requiring three retirements in them is
	// well inside that and well outside "none", which is what waiting for
	// `done` would give.
	if (bg_retire < 3) begin
		errors = errors + 1;
		$display("FAIL: %0d instructions retired while an FP operation was in flight, expected >= 3 (no background release)", bg_retire);
	end
	if (dbg_d1 !== 32'h0000_0004) begin
		errors = errors + 1;
		$display("FAIL: D1 = %h, expected 00000004 (the instructions behind the FP op did not run)", dbg_d1);
	end
	if (dbg_d2 !== 32'h0000_000C) begin
		errors = errors + 1;
		$display("FAIL: D2 = %h, expected 0000000C (the reader did not wait for the unit)", dbg_d2);
	end
	if (fp_dbl) begin
		errors = errors + 1;
		$display("FAIL: the core requested the unit while it was busy");
	end

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("%0d CHECK(S) FAILED", errors);
	$finish;
end

endmodule
