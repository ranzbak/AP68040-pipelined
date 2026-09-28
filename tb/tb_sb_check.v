//--------------------------------------------------------------------------//
// tb_sb_check.v - the store buffer's order checker (findings/storebuf/     //
// plan.md, stage 0).  Bench-only: it watches the core through the ports   //
// its parent connects (hierarchical references into ap040_pipe_core).     //
//                                                                          //
// Two byte streams, compared in order:                                     //
//   program order  every store WB retires (not a faulted one), byte by    //
//                  byte, most significant first;                           //
//   bus order      every store transfer the BCU completes on the core's   //
//                  memory port, byte by byte (a page-split store's single //
//                  bytes as they go).                                      //
// They must be the same sequence: a posted store is written after it      //
// retires, a synchronous one before, but never out of order, never twice, //
// never lost.  A POSTED store that bus-errors (bf_v, fatal) is dropped    //
// from the program stream unwritten.  A SYNCHRONOUS store split at a page  //
// boundary (translation on) that faults on a later byte has written its   //
// earlier bytes but never retires (the instruction restarts or completes  //
// through WB1): sf_v drops those sf_n bytes from the bus stream.           //
//                                                                          //
// Two read rules, at the clock the read goes:                              //
//   br_v  a read on the port (the slow path, which may be I/O): no retired //
//         store may still be unwritten -- the FIFO drains first;          //
//   fr_v  a read answered by the data read path (never on the port): no   //
//         retired, unwritten store may overlap its bytes.                  //
//                                                                          //
// Counters (the plan's perf counters), printed by report():               //
//   occ[n]   enabled clocks with n stores in the FIFO                      //
//   full     enabled clocks WB held a posted store because the FIFO was   //
//            full                                                          //
//   rdw      enabled clocks a slot read waited for the FIFO to drain      //
//   fw       enabled clocks a fetch wanted the port and the FIFO held     //
//            stores                                                        //
//   syw      enabled clocks a synchronous store waited for the FIFO       //
//                                                                          //
// At every reset the streams are settled: bytes retired but never written //
// are an error (a lost store); bytes written but not yet retired are a    //
// synchronous store still in WB when the run ended, and are dropped.      //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_sb_check #(parameter QN = 4096)
(
	input         clk,
	input         nreset,
	input         ce,
	// a store WB retires this enabled clock (program order)
	input         ret_v,
	input  [31:0] ret_a,
	input   [1:0] ret_s,
	input  [31:0] ret_d,
	// a store transfer completes on the port this enabled clock (bus order)
	input         bw_v,
	input  [31:0] bw_a,
	input   [1:0] bw_s,
	input  [31:0] bw_d,
	// a posted store's transfer bus-errored (dropped unwritten)
	input         bf_v,
	input  [31:0] bf_a,
	input   [1:0] bf_s,
	// a synchronous split store faulted after sf_n of its bytes were written
	input         sf_v,
	input   [1:0] sf_n,
	// a read goes on the port / is answered by the data read path
	input         br_v,
	input  [31:0] br_a,
	input         fr_v,
	input  [31:0] fr_a,
	input   [1:0] fr_s,
	// counters
	input   [2:0] occ_n,
	input         full_hold,
	input         rd_wait,
	input         f_wait,
	input         sy_wait
);

reg  [31:0] pa [0:QN-1];   // program stream: address
reg   [7:0] pd [0:QN-1];   //                 data
reg  [31:0] ba [0:QN-1];   // bus stream
reg   [7:0] bd [0:QN-1];
integer ph = 0, pt = 0, bh = 0, bt = 0;   // heads (next to match) and tails (next free)
integer bad = 0, n_match = 0, n_lost = 0;
integer occ [0:7];
integer full = 0, rdw = 0, fw = 0, syw = 0;
integer k, n, j;
reg     was_reset = 1'b1;

function integer nb(input [1:0] s);
	nb = (s == 2'd0) ? 1 : (s == 2'd1) ? 2 : 4;
endfunction

task complain(input [8*64-1:0] what, input [31:0] a);
	begin
		bad = bad + 1;
		if (bad <= 10) $display("FAIL: store order: %0s at %h", what, a);
	end
endtask

// settle the streams (a reset, or the end of the run)
task settle;
	begin
		if (pt > ph) complain("store retired but never written", pa[ph % QN]);
		ph = 0; pt = 0; bh = 0; bt = 0;
	end
endtask

task report(input [8*40-1:0] tag);
	begin
		$display("SBCHK %0s: %0d bytes matched in order, %0d dropped (posted-store bus error), %0d error(s)",
		         tag, n_match, n_lost, bad);
		$display("SBCHK   FIFO occupancy (enabled clocks): 0:%0d 1:%0d 2:%0d 3:%0d 4:%0d",
		         occ[0], occ[1], occ[2], occ[3], occ[4]);
		$display("SBCHK   waits: WB full %0d  read drain %0d  fetch behind stores %0d  sync store behind FIFO %0d",
		         full, rdw, fw, syw);
	end
endtask

initial for (k = 0; k < 8; k = k + 1) occ[k] = 0;

always @(posedge clk) begin
	if (!nreset) begin
		if (!was_reset) settle;
		was_reset = 1'b1;
	end else if (ce) begin
		was_reset = 1'b0;
		// the read rules, against the state before this edge's events
		// (after matching, at most one stream holds bytes: pt > ph means
		// retired stores are still unwritten)
		if (br_v && pt > ph)
			complain("port read went with a retired store unwritten", br_a);
		if (fr_v)
			for (j = ph; j < pt; j = j + 1)
				if (pa[j % QN] >= fr_a && pa[j % QN] < fr_a + nb(fr_s))
					complain("fast read overlapped a retired, unwritten store", fr_a);
		// the streams
		if (ret_v) begin
			n = nb(ret_s);
			for (k = 0; k < n; k = k + 1) begin
				pa[pt % QN] = ret_a + k; pd[pt % QN] = ret_d[8 * (n - 1 - k) +: 8]; pt = pt + 1;
			end
		end
		if (bw_v) begin
			n = nb(bw_s);
			for (k = 0; k < n; k = k + 1) begin
				ba[bt % QN] = bw_a + k; bd[bt % QN] = bw_d[8 * (n - 1 - k) +: 8]; bt = bt + 1;
			end
		end
		// a posted store that bus-errored: its bytes leave the program
		// stream unwritten (they are the oldest unwritten ones)
		if (bf_v) begin
			n = nb(bf_s);
			for (k = 0; k < n; k = k + 1)
				if (bt == bh && ph < pt && pa[ph % QN] == bf_a + k) begin ph = ph + 1; n_lost = n_lost + 1; end
				else complain("faulted posted store is not the oldest unwritten one", bf_a + k);
		end
		if (sf_v)
			for (k = 0; k < sf_n; k = k + 1)
				if (bt > bh) bt = bt - 1;
				else complain("faulted split store's bytes already matched", bw_a);
		while (ph < pt && bh < bt) begin
			if (pa[ph % QN] !== ba[bh % QN] || pd[ph % QN] !== bd[bh % QN]) begin
				bad = bad + 1;
				if (bad <= 10)
					$display("FAIL: store order: program byte %h=%h, bus byte %h=%h",
					         pa[ph % QN], pd[ph % QN], ba[bh % QN], bd[bh % QN]);
			end else n_match = n_match + 1;
			ph = ph + 1; bh = bh + 1;
		end
		if (pt - ph >= QN || bt - bh >= QN) complain("stream overflow", 32'd0);
		// counters
		occ[occ_n] = occ[occ_n] + 1;
		if (full_hold) full = full + 1;
		if (rd_wait) rdw = rdw + 1;
		if (f_wait) fw = fw + 1;
		if (sy_wait) syw = syw + 1;
	end
end

endmodule
