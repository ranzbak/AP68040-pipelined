// Window timer for lib/AP68040's tb_ap040_program.v (the reference core):
// clocks between the program's $F1F0 open/close stores, per wait profile.
module tb_win_ref;
reg on = 0; integer n = 0;
always @(posedge tb_ap040_program.clk) begin
	if (on) n = n + 1;
	if (tb_ap040_program.dut.mem_ack && tb_ap040_program.dut.mem_write &&
	    tb_ap040_program.dut.mem_addr[15:0] == 16'hF1F0) begin
		if (|tb_ap040_program.dut.mem_wdata[15:0]) begin on = 1; n = 0; end
		else if (on) begin on = 0; $display("WINDOW reference profile %0d: %0d clocks", tb_ap040_program.phase, n); end
	end
end
endmodule
