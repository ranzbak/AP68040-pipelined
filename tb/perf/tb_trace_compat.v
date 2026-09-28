// tb_trace_compat.v -- companion top for tb_ap040_pipe_compat.v + tb_perf_compat.v:
// an event trace of the measured window (pp_win) for trace_gaps.py.
//   R <clk> <pc>          an instruction retired (WB's last micro-op)
//   D <clk> <src> <pc>    a redirect (src: X=EX, F=EA-fetch, C=EA-calc, I=ID, S=SMC) to <pc>
//   F <clk> <pc>          a data read answered by the fast path (pc: the reading instruction:
//                         EA-fetch's, or EA-calc's for an early read)
//   S <clk> <pc>          a data read answered from the port
// +trace=<file> names the output (default trace.txt).  Enabled clocks only.
module tb_trace_compat;
`define TC tb_ap040_pipe_compat.dut.core
integer fd, clk_n = 0;
reg [31:0] rd_owner = 0;
reg        fast_q = 0;   // rd_ack is registered: the fast answer was the clock before
reg [8*256-1:0] tf;
initial begin
	if (!$value$plusargs("trace=%s", tf)) tf = "trace.txt";
	fd = $fopen(tf, "w");
end
always @(posedge tb_ap040_pipe_compat.clk) if (tb_perf_compat.pp_win && tb_ap040_pipe_compat.dut.ce_core) begin
	clk_n = clk_n + 1;
	if (`TC.wb_valid) $fdisplay(fd, "R %0d %h", clk_n, `TC.wb_pc);
	if (`TC.redirect_valid)
		$fdisplay(fd, "D %0d %s %h", clk_n,
		          `TC.wb_smc ? "S" : `TC.ex_redirect ? "X" : `TC.eaf_redir_v ? "F" : `TC.eac_redir_v ? "C" : "I",
		          `TC.redirect_pc);
	if (`TC.d_rd_ack) $fdisplay(fd, "%s %0d %h", fast_q ? "F" : "S", clk_n, rd_owner);
	fast_q = `TC.g_bus.d_rd_fast;
	if (`TC.d_rd_req) rd_owner = `TC.u_eaf.use_early ? `TC.id_o.pc : `TC.eac_o.i.pc;
end
endmodule
