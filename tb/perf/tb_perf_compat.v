// Companion top for tb_ap040_pipe_compat.v: the cycle-accounting probe
// (perf_probe.vh) on the compat wrapper.  A program opens the measured
// window with a nonzero word store to $F1F0 and closes it with a zero one;
// each window prints one PERF report, tagged with the bench's wait profile.
//   iverilog -g2012 -I ../../rtl -I ../../rtl/compat -I . -o x.vvp \
//            ../tb_ap040_pipe_compat.v tb_perf_compat.v <core + compat sources>
module tb_perf_compat;
reg pp_win = 0;
always @(posedge tb_ap040_pipe_compat.clk)
	if (tb_ap040_pipe_compat.dut.mem_ack && tb_ap040_pipe_compat.dut.mem_write &&
	    tb_ap040_pipe_compat.dut.mem_addr[15:0] == 16'hF1F0)
		pp_win <= |tb_ap040_pipe_compat.dut.mem_wdata[15:0];
`define PP_W   tb_ap040_pipe_compat.dut
`define PP_EN  pp_win
`define PP_TAG $sformatf("compat profile %0d", tb_ap040_pipe_compat.phase)
`include "perf_probe.vh"
endmodule
