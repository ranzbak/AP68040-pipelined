// Companion top for tb_ap040_pipe_compat.v: the 2^31-word freeze.
//
// IF counts the words it hands to ID (`issued`) against PROG_WORDS, a bound
// the milestone benches use to end a program.  The compat wrapper -- every
// real build -- passes 32'h7FFF_FFFF, meaning "no bound", but the count was
// compared anyway: after 2^31 - 1 words IF handed ID nothing ever again, a
// hard freeze with no fault and no halt, a few minutes into a running Amiga.
//
// This presets the counter to 256 words short of that value part way into a
// compat program (t_integer).  Before the fix the core wedges (phase
// timeout, EA-fetch empty, pc stuck); after it the program runs to its end.
// Built by tb/run_pipe_tests.sh as the compat:issued_wrap leg.
`ifndef ISSUED_T
 `define ISSUED_T 200000
`endif
module tb_issued_wrap;
initial begin
	#(`ISSUED_T);
	tb_ap040_pipe_compat.dut.core.u_if.issued = 32'h7FFF_FF00;
	$display("issued_wrap: IF's word count preset to %h at %0t",
	         tb_ap040_pipe_compat.dut.core.u_if.issued, $time);
end
endmodule
