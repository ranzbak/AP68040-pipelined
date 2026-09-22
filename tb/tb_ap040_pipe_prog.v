//--------------------------------------------------------------------------//
// tb_ap040_pipe_prog.v - program bench for the pipelined core (Minimig     //
// plan M1+)                                                                //
//                                                                          //
//   vvp tb.vvp +prog=<image.hex> +expect=<file.exp> [+cycles=N]            //
//                                                                          //
// Loads a flat image (one 16-bit word per line from address 0, bin2hex.py  //
// format) into the L1 array, runs the core from reset with                 //
// RESET_FROM_VECTORS=1 (ISP/PC from vectors 0/1), stops when the halt PC   //
// retires (or after +cycles clocks, default 20000), then checks every line //
// of the expect file:                                                      //
//   halt <pc>            stop when the instruction at <pc> retires         //
//                        (required; the first line normally)               //
//   d0..d7 a0..a6 <v>    register value (hex)                              //
//   usp|isp|msp <v>                                                        //
//   sr <v>  ccr <v>      (ccr: the low 5 bits)                             //
//   vbr <v>                                                                //
//   m8|m16|m32 <addr> <v>  memory (big-endian)                             //
//   noread <addr>        no data read may touch this byte (pure writes)     //
//   # ...                comment (the # a word of its own)                 //
// Prints "ALL TESTS PASSED" or one FAIL line per mismatch.                  //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ap040_pipe_prog;

parameter [31:0] PC_RESET = 32'h0000_0400;
parameter         L1_AW   = 15;     // 64K: the whole image (t_integer uses $3000-$3400 and $F100)
localparam        L1_WORDS = (1 << L1_AW);

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

wire        dbg_wb_valid;
wire [31:0] dbg_wb_pc;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire  [4:0] dbg_ccr;
wire [15:0] dbg_sr;

ap040_pipe_core #(
	.PC_RESET(PC_RESET), .PROG_WORDS(32'h7FFF_FFFF), .L1_AW(L1_AW), .RESET_FROM_VECTORS(1)
) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.dbg_if_valid(), .dbg_if_pc(), .dbg_id_valid(), .dbg_id_pc(),
	.dbg_eac_valid(), .dbg_eac_pc(), .dbg_eaf_valid(), .dbg_eaf_pc(),
	.dbg_ex_valid(), .dbg_ex_pc(), .dbg_wb_valid(dbg_wb_valid), .dbg_wb_pc(dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7),
	.dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr)
);

function [7:0] mb(input [31:0] a);
	reg [15:0] w;
	begin
		w  = dut.u_l1.mem[((a - PC_RESET) >> 1) & (L1_WORDS - 1)];
		mb = a[0] ? w[7:0] : w[15:8];
	end
endfunction

function [31:0] reg_by_name(input [63:0] n);   // key as a right-justified ASCII vector
	case (n)
		"d0": reg_by_name = dbg_d0;  "d1": reg_by_name = dbg_d1;
		"d2": reg_by_name = dbg_d2;  "d3": reg_by_name = dbg_d3;
		"d4": reg_by_name = dbg_d4;  "d5": reg_by_name = dbg_d5;
		"d6": reg_by_name = dbg_d6;  "d7": reg_by_name = dbg_d7;
		"a0": reg_by_name = dut.u_regfile.areg[0];  "a1": reg_by_name = dut.u_regfile.areg[1];
		"a2": reg_by_name = dut.u_regfile.areg[2];  "a3": reg_by_name = dut.u_regfile.areg[3];
		"a4": reg_by_name = dut.u_regfile.areg[4];  "a5": reg_by_name = dut.u_regfile.areg[5];
		"a6": reg_by_name = dut.u_regfile.areg[6];
		"usp": reg_by_name = dut.u_regfile.usp;
		"isp": reg_by_name = dut.u_regfile.isp;
		"msp": reg_by_name = dut.u_regfile.msp;
		"sr":  reg_by_name = {16'd0, dbg_sr};
		"ccr": reg_by_name = {27'd0, dbg_ccr};
		"vbr": reg_by_name = dut.vbr;
		default: reg_by_name = 32'hDEAD_BEEF;
	endcase
endfunction

reg [15:0] img [0:32767];
string progf, expf;
reg [63:0] key;           // (not a string: Icarus crashes comparing string characters)
integer i, fd, rc, ok, max_cycles, cycles, errors, nchk;
reg [31:0] halt_pc, a, v, got;
reg        done = 0;

always @(posedge clk)
	if (nreset && dbg_wb_valid && dbg_wb_pc == halt_pc) done = 1;

// "noread <addr>": no data read may touch that byte (CLR and Scc to memory
// are pure writes on the 68040)
reg [31:0] noread [0:15];
integer    n_noread = 0, reads_bad = 0, nr;
reg [31:0] rlen;
always @(posedge clk)
	if (nreset && dut.u_l1.rd_req) begin
		rlen = (dut.u_l1.rd_size == 2'd0) ? 1 : (dut.u_l1.rd_size == 2'd1) ? 2 : 4;
		for (nr = 0; nr < n_noread; nr = nr + 1)
			if (noread[nr] >= dut.u_l1.rd_addr && noread[nr] < dut.u_l1.rd_addr + rlen) begin
				reads_bad = reads_bad + 1;
				$display("FAIL: data read of %h (size %0d) touches noread byte %h", dut.u_l1.rd_addr, rlen, noread[nr]);
			end
	end

// "rbcount <n>" + "rb <addr>" lines: exactly n locked write-backs (CAS/CAS2
// mismatch, M68040UM p. 7-26), at those addresses in that order, each
// rewriting the bytes memory holds
integer n_rb = 0, want_rb = -1, rb_bad = 0, kb, n_rbl = 0;
reg [31:0] rb_at [0:31];
reg [2:0] rbn;
always @(posedge clk)
	if (nreset && dut.u_l1.wr_req && dut.exe_o.st_rb) begin
		if (n_rb < n_rbl && rb_at[n_rb] != dut.u_l1.wr_addr) begin
			rb_bad = rb_bad + 1;
			$display("FAIL: locked write-back #%0d at %h, expected %h", n_rb, dut.u_l1.wr_addr, rb_at[n_rb]);
		end
		n_rb = n_rb + 1;
		rbn = (dut.u_l1.wr_size == 2'd0) ? 1 : (dut.u_l1.wr_size == 2'd1) ? 2 : 4;
		for (kb = 0; kb < rbn; kb = kb + 1)
			if (mb(dut.u_l1.wr_addr + kb) !== dut.u_l1.wr_data[8 * (rbn - 1 - kb) +: 8]) begin
				rb_bad = rb_bad + 1;
				$display("FAIL: locked write-back at %h changes byte %0d", dut.u_l1.wr_addr, kb);
			end
	end

// "readonce <addr>": exactly one data read touches that byte (MOVEM/MOVEP
// must not read an operand twice: I/O side effects)
reg [31:0] ro_at [0:15];
integer    ro_n [0:15];
integer    n_ro = 0, kr;
always @(posedge clk)
	if (nreset && dut.u_l1.rd_req)
		for (kr = 0; kr < n_ro; kr = kr + 1)
			if (ro_at[kr] >= dut.u_l1.rd_addr &&
			    ro_at[kr] < dut.u_l1.rd_addr + ((dut.u_l1.rd_size == 2'd0) ? 1 : (dut.u_l1.rd_size == 2'd1) ? 2 : 4))
				ro_n[kr] = ro_n[kr] + 1;

// "fc <addr> <fc>": every data read and write touching that byte uses that
// function code (MOVES: SFC/DFC; the rest: 5 supervisor / 1 user data)
reg [31:0] fc_at [0:15];
reg  [2:0] fc_want [0:15];
integer    n_fc = 0, fc_bad = 0, fc_hits = 0, kf;
always @(posedge clk)
	if (nreset) for (kf = 0; kf < n_fc; kf = kf + 1) begin
		if (dut.u_l1.rd_req && fc_at[kf] >= dut.u_l1.rd_addr &&
		    fc_at[kf] < dut.u_l1.rd_addr + ((dut.u_l1.rd_size == 2'd0) ? 1 : (dut.u_l1.rd_size == 2'd1) ? 2 : 4)) begin
			fc_hits = fc_hits + 1;
			if (dut.d_rd_fc !== fc_want[kf]) begin
				fc_bad = fc_bad + 1;
				$display("FAIL: read of %h with FC %0d, expected %0d", dut.u_l1.rd_addr, dut.d_rd_fc, fc_want[kf]);
			end
		end
		if (dut.u_l1.wr_req && fc_at[kf] >= dut.u_l1.wr_addr &&
		    fc_at[kf] < dut.u_l1.wr_addr + ((dut.u_l1.wr_size == 2'd0) ? 1 : (dut.u_l1.wr_size == 2'd1) ? 2 : 4)) begin
			fc_hits = fc_hits + 1;
			if (dut.exe_o.st_fc !== fc_want[kf]) begin
				fc_bad = fc_bad + 1;
				$display("FAIL: write of %h with FC %0d, expected %0d", dut.u_l1.wr_addr, dut.exe_o.st_fc, fc_want[kf]);
			end
		end
	end

// "inimage": no data access may fall outside the image.  The L1 model
// aliases the high address bits (ea_all relies on it), so a wrong high
// address (a bitfield offset shifted without its sign, say) would otherwise
// go unseen.
reg inimage = 0;
always @(posedge clk)
	if (nreset && inimage && ((dut.u_l1.rd_req && (dut.u_l1.rd_addr >> (L1_AW + 1)) != 0) ||
	               (dut.u_l1.wr_req && (dut.u_l1.wr_addr >> (L1_AW + 1)) != 0))) begin
		reads_bad = reads_bad + 1;
		if (dut.u_l1.rd_req && (dut.u_l1.rd_addr >> (L1_AW + 1)) != 0)
			$display("FAIL: data read outside the image at %h", dut.u_l1.rd_addr);
		else
			$display("FAIL: data write outside the image at %h", dut.u_l1.wr_addr);
	end

initial begin
	if (!$value$plusargs("prog=%s", progf) || !$value$plusargs("expect=%s", expf)) begin
		$display("usage: +prog=<image.hex> +expect=<file.exp> [+cycles=N]");
		$finish;
	end
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 20000;
	for (i = 0; i < 32768; i = i + 1) img[i] = 16'h4E71;
	$readmemh(progf, img);
	for (i = 0; i < L1_WORDS; i = i + 1)
		dut.u_l1.mem[(i - (PC_RESET >> 1)) & (L1_WORDS - 1)] = img[i];
	// the halt line first
	halt_pc = 32'hFFFF_FFFE;
	fd = $fopen(expf, "r");
	if (fd == 0) begin $display("FAIL: cannot open %0s", expf); $finish; end
	ok = 1;
	while (!$feof(fd) && ok) begin
		ok = ($fscanf(fd, "%s", key) == 1);
		if (!ok) ;
		else if (key == "halt") rc = $fscanf(fd, "%h", halt_pc);
		else begin
			if (key == "#") begin : skipline
				integer ch;
				ch = 0;
				while (ch != 10 && !$feof(fd)) ch = $fgetc(fd);
			end else if (key == "m8" || key == "m16" || key == "m32") rc = $fscanf(fd, "%h %h", a, v);
			else if (key == "noread") begin
				rc = $fscanf(fd, "%h", a);
				noread[n_noread] = a; n_noread = n_noread + 1;
			end else if (key == "inimage") inimage = 1;
			else if (key == "readonce") begin rc = $fscanf(fd, "%h", a); ro_at[n_ro] = a; ro_n[n_ro] = 0; n_ro = n_ro + 1; end
			else if (key == "rbcount") rc = $fscanf(fd, "%d", want_rb);
			else if (key == "fc") begin rc = $fscanf(fd, "%h %d", a, v); fc_at[n_fc] = a; fc_want[n_fc] = v[2:0]; n_fc = n_fc + 1; end
			else if (key == "rb") begin rc = $fscanf(fd, "%h", a); rb_at[n_rbl] = a; n_rbl = n_rbl + 1; end
			else rc = $fscanf(fd, "%h", v);
		end
	end
	$fclose(fd);
	repeat (3) @(posedge clk);
	nreset = 1;
	for (cycles = 0; cycles < max_cycles && !done; cycles = cycles + 1) @(posedge clk);
	repeat (2) @(posedge clk);
	errors = 0; nchk = 0;
	if (!done) begin
		errors = errors + 1;
		$display("FAIL: halt pc %h never retired in %0d clocks (last retired %h)", halt_pc, cycles, dbg_wb_pc);
	end
	fd = $fopen(expf, "r");
	ok = 1;
	while (!$feof(fd) && ok) begin
		ok = ($fscanf(fd, "%s", key) == 1);
		if (!ok) ;
		else if (key == "halt") rc = $fscanf(fd, "%h", v);
		else if (key == "noread") rc = $fscanf(fd, "%h", v);
		else if (key == "inimage") ;
		else if (key == "readonce") rc = $fscanf(fd, "%h", v);
		else if (key == "rbcount") rc = $fscanf(fd, "%d", v);
		else if (key == "fc") rc = $fscanf(fd, "%h %d", a, v);
		else if (key == "rb") rc = $fscanf(fd, "%h", v);
		else if (key == "#") begin : skipline2
			integer ch;
			ch = 0;
			while (ch != 10 && !$feof(fd)) ch = $fgetc(fd);
		end else if (key == "m8" || key == "m16" || key == "m32") begin
			rc = $fscanf(fd, "%h %h", a, v);
			if (key == "m8")       got = {24'd0, mb(a)};
			else if (key == "m16") got = {16'd0, mb(a), mb(a + 1)};
			else                   got = {mb(a), mb(a + 1), mb(a + 2), mb(a + 3)};
			nchk = nchk + 1;
			if (got !== v) begin
				errors = errors + 1;
				$display("FAIL: %0s[%h] = %h, expected %h", key, a, got, v);
			end
		end else begin
			rc = $fscanf(fd, "%h", v);
			got = reg_by_name(key);
			nchk = nchk + 1;
			if (got !== v) begin
				errors = errors + 1;
				$display("FAIL: %0s = %h, expected %h", key, got, v);
			end
		end
	end
	$fclose(fd);
	errors = errors + reads_bad + rb_bad + fc_bad;
	if (n_fc > 0 && fc_hits == 0) begin
		errors = errors + 1;
		$display("FAIL: no access touched any 'fc' byte");
	end
	for (kr = 0; kr < n_ro; kr = kr + 1)
		if (ro_n[kr] != 1) begin
			errors = errors + 1;
			$display("FAIL: byte %h read %0d times, expected once", ro_at[kr], ro_n[kr]);
		end
	if (want_rb >= 0 && n_rb != want_rb) begin
		errors = errors + 1;
		$display("FAIL: %0d locked write-backs, expected %0d", n_rb, want_rb);
	end
	if (errors == 0) $display("ALL TESTS PASSED (%0d checks, halt after %0d clocks)", nchk, cycles);
	else $display("%0d CHECK(S) FAILED", errors);
	$finish;
end

endmodule
