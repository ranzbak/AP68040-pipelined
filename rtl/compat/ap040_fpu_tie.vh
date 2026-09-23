//--------------------------------------------------------------------------//
// ap040_fpu_tie.vh - the lifted ap040_fpu on the pipelined core's fp_* port  //
// group, with everything M10.1 step 3 does not drive yet tied off.          //
//                                                                          //
// Included by rtl/compat/ap040_pipe_tg68k_compat.v (inside                 //
// `generate if (AP040_HAS_FPU)`) and by tb/tb_ap040_pipe_prog.v with        //
// -DFPU_REAL, so the bench and the shipping wrapper cannot drift apart:     //
// the programs that pass in simulation drive exactly the instance the       //
// bitstream carries.                                                        //
//                                                                          //
// The names it expects in scope are the core's own: fp_req, fp_op_class,   //
// fp_opmode, fp_src_fmt, fp_src_r, fp_dst_r, fp_din, fp_ia_we,             //
// fp_ia_wdata (driven by the core) and fp_done, fp_accepted, fp_unimp,     //
// fp_unsupp, fp_dout (driven back), plus clk, nreset and fp_ce.            //
//                                                                          //
// TIED OFF, and each one is a recorded gap, not an oversight:              //
//   cr_* / bsun_*        opclass 100/101 (FPCR/FPSR/FPIAR) is not decoded   //
//                        yet, so nothing can read or write them.           //
//   fm_*                 FMOVEM (opclass 110/111) is not decoded yet.      //
//   fsave_ack/frestore_* FSAVE/FRESTORE still take M10.0's format $4       //
//                        frame; the unit's state frame is not consumed.    //
//   pend_capture         the deferred-exception frame goes with (d).        //
//   exc_req / exc_vec    the ARITHMETIC exceptions (vectors 48-54) are      //
//                        step (d).  Until it exists an ENABLED arithmetic   //
//                        exception is silently dropped, so every program    //
//                        here must leave the FPCR enable byte at zero --    //
//                        which it is out of reset and nothing can change.  //
//--------------------------------------------------------------------------//

ap040_fpu u_fpu
(
	.clk(clk), .nreset(nreset), .ce(fp_ce),

	.req(fp_req), .op_class(fp_op_class), .opmode(fp_opmode),
	.src_fmt(fp_src_fmt), .src_r(fp_src_r), .dst_r(fp_dst_r), .din(fp_din),
	.done(fp_done), .accepted(fp_accepted),
	.unimp(fp_unimp), .unsupp(fp_unsupp),
	.exc_req(), .exc_vec(), .dout(fp_dout),
	.fpcc(),

	.cr_sel(2'd0), .cr_we(1'b0), .cr_wdata(32'd0), .cr_rdata(),
	.bsun_req(1'b0), .bsun_enable(),

	.ia_we(fp_ia_we), .ia_wdata(fp_ia_wdata),

	.fm_sel(3'd0), .fm_we(1'b0), .fm_wdata(96'd0), .fm_rdata(),

	.fpu_used(), .fstate_unimp(),
	.fstate_cmd1(), .fstate_cmd3(),
	.fstate_stag(), .fstate_dtag(), .fstate_flags(),
	.fstate_fpt(), .fstate_et(),
	.fsave_ack(1'b0), .frestore_idle(1'b0), .frestore_unimp(1'b0),
	.pend_capture(1'b0), .cur_vec(), .frestore_e1_pend(),
	.fstate_grs(), .fstate_wbte15(), .fstate_busy(),
	.fstate_wbt(), .fstate_fpiar_c(),
	.frestore_wbt(96'd0), .frestore_fpiar(32'd0), .frestore_busy(1'b0),
	.frestore_cmd1(16'd0), .frestore_cmd3(16'd0),
	.frestore_stag(3'd0), .frestore_dtag(3'd0), .frestore_flags(3'd0),
	.frestore_fpt(96'd0), .frestore_et(96'd0),
	.frestore_grs(3'd0), .frestore_wbte15(1'b0),
	.fp_reset(1'b0)
);
