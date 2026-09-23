//--------------------------------------------------------------------------//
// tb_fpu_stub.v - a fixed-latency stand-in for ap040_fpu (Minimig plan      //
// M10.1(c)).                                                                //
//                                                                           //
// It exists so the core's req / accepted / done INTERLOCK can be tested by  //
// itself, before the 96-bit memory operand path (M10.1(b)) and before the   //
// real unit's floating-point arithmetic becomes the oracle.  It is a bench  //
// model: nothing in rtl/ instantiates it and it never reaches a bitstream.  //
//                                                                           //
// It honours exactly the contract ap040_fpu's header states, and nothing    //
// else:                                                                     //
//   * `req` is sampled when the unit is idle, with the command fields and   //
//     `din` (LEFT aligned) valid in that clock;                             //
//   * `accepted` rises only for the long (arithmetic) operations, a few     //
//     clocks in, and means classification is past -- after it, only `done`  //
//     can follow.  A move never asserts it, exactly as the real unit does   //
//     not (its `accepted` is a decode of the arithmetic states alone);      //
//   * `done` pulses for one clock with `dout` (LEFT aligned);               //
//   * `unimp` / `unsupp` pulse INSTEAD, before `accepted`, and the unit     //
//     stays idle.                                                           //
//                                                                           //
// Its "arithmetic" is 32-bit integer, so a program written against it says  //
// nothing about floating point -- that is the point: these tests check      //
// sequencing, and t_fpu.s becomes the oracle when the real unit goes in.    //
// The stub's register file is 32 bits per FPn.                              //
//                                                                           //
// Two deliberate probes, because a mutant has to be VISIBLE in a program:   //
//   * a `req` while the unit is busy sets dbl_req and poisons the           //
//     destination register with $BADBAD00 -- so removing the core's         //
//     structural stall changes an architectural value, not just a flag;     //
//   * a stored register whose top byte is $FF is the stand-in for an        //
//     unsupported data type (vector 55), which the real unit raises for a   //
//     denormal or unnormal register operand on an opclass 011 store.        //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_fpu_stub #(
	parameter LAT_MOVE  = 3,      // FMOVE to/from an FP register
	parameter LAT_ARITH = 9       // FADD/FSUB/FMUL: long enough to see the background
)
(
	input             clk,
	input             nreset,
	input             ce,

	input             req,
	input       [2:0] op_class,
	input       [6:0] opmode,
	input       [2:0] src_fmt,
	input       [2:0] src_r,
	input       [2:0] dst_r,
	input      [95:0] din,
	output reg        done,
	output            accepted,
	output reg        unimp,
	output reg        unsupp,
	output reg [95:0] dout,

	output reg        dbl_req      // a request arrived while the unit was busy
);

reg [31:0] fr [0:7];
integer    k;

reg        busy;
reg        arith;
reg  [7:0] cnt;
reg  [7:0] tgt;
reg  [2:0] r_dst;
reg        r_store;
reg  [2:0] r_fmt;
reg [31:0] r_val;              // the result, computed at dispatch

// the real unit's `accepted` is a decode of its arithmetic states: it is
// high for the clocks between classification and completion, and never for
// a move.  The last clock is `done`, so accepted drops there.
assign accepted = busy && arith && (cnt >= 8'd2) && (cnt < tgt);

// is this opmode in the stub's "hardware"?  Everything else is the FPSP
// route: unimp, vector 11 (FSIN $0E is the case the programs use).
function automatic op_in_hw(input [6:0] om);
	case (om)
		7'h00, 7'h22, 7'h28, 7'h23: op_in_hw = 1'b1;   // FMOVE FADD FSUB FMUL
		default:                    op_in_hw = 1'b0;
	endcase
endfunction

// a source operand out of the left-aligned din window, by source specifier
function automatic [31:0] src_val(input [2:0] fmt, input [95:0] d);
	case (fmt)
		3'b100:  src_val = {{16{d[95]}}, d[95:80]};    // word integer
		3'b110:  src_val = {{24{d[95]}}, d[95:88]};    // byte integer
		default: src_val = d[95:64];                   // long, single
	endcase
endfunction

// ... and the result back into it
function automatic [95:0] dst_win(input [2:0] fmt, input [31:0] v);
	case (fmt)
		3'b100:  dst_win = {v[15:0], 80'd0};
		3'b110:  dst_win = {v[7:0],  88'd0};
		default: dst_win = {v,       64'd0};
	endcase
endfunction

always @(posedge clk) begin
	if (!nreset) begin
		busy <= 1'b0; arith <= 1'b0; cnt <= 8'd0; tgt <= 8'd0;
		done <= 1'b0; unimp <= 1'b0; unsupp <= 1'b0; dout <= 96'd0;
		r_dst <= 3'd0; r_store <= 1'b0; r_fmt <= 3'd0; r_val <= 32'd0;
		dbl_req <= 1'b0;
		for (k = 0; k < 8; k = k + 1) fr[k] <= 32'd0;
	end else if (ce) begin
		done <= 1'b0; unimp <= 1'b0; unsupp <= 1'b0;
		if (busy) begin
			if (req) begin
				// the core must not do this: one operation at a time
				dbl_req <= 1'b1;
				fr[dst_r] <= 32'hBADBAD00;
			end
			cnt <= cnt + 8'd1;
			if (cnt + 8'd1 == tgt) begin
				busy <= 1'b0;
				done <= 1'b1;
				if (r_store) dout <= dst_win(r_fmt, r_val);
				else         fr[r_dst] <= r_val;
			end
		end else if (req) begin
			r_dst   <= dst_r;
			r_fmt   <= src_fmt;
			r_store <= (op_class == 3'b011);
			case (op_class)
				3'b011: begin
					// FMOVE FPn,<ea>: src_r names the register (the core maps
					// the encoding's destination field onto it)
					if (fr[src_r][31:24] == 8'hFF) begin
						unsupp <= 1'b1;                 // unsupported data type
					end else begin
						busy <= 1'b1; arith <= 1'b0; cnt <= 8'd0; tgt <= LAT_MOVE[7:0];
						r_val <= fr[src_r];
					end
				end
				3'b010: begin
					// <ea>{fmt} -> FPn
					if (!op_in_hw(opmode)) unimp <= 1'b1;
					else begin
						busy <= 1'b1; cnt <= 8'd0;
						arith <= (opmode != 7'h00);
						tgt   <= (opmode != 7'h00) ? LAT_ARITH[7:0] : LAT_MOVE[7:0];
						case (opmode)
							7'h22:   r_val <= fr[dst_r] + src_val(src_fmt, din);
							7'h28:   r_val <= fr[dst_r] - src_val(src_fmt, din);
							7'h23:   r_val <= fr[dst_r] * src_val(src_fmt, din);
							default: r_val <= src_val(src_fmt, din);
						endcase
					end
				end
				default: begin
					// FPm -> FPn (opclass 000); src_r is FPm
					if (!op_in_hw(opmode)) unimp <= 1'b1;
					else begin
						busy <= 1'b1; cnt <= 8'd0;
						arith <= (opmode != 7'h00);
						tgt   <= (opmode != 7'h00) ? LAT_ARITH[7:0] : LAT_MOVE[7:0];
						case (opmode)
							7'h22:   r_val <= fr[dst_r] + fr[src_r];
							7'h28:   r_val <= fr[dst_r] - fr[src_r];
							7'h23:   r_val <= fr[dst_r] * fr[src_r];
							default: r_val <= fr[src_r];
						endcase
					end
				end
			endcase
		end
	end
end

endmodule
