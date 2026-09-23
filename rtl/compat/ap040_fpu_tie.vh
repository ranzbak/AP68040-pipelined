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
// fp_ia_wdata, fp_cr_sel, fp_cr_we, fp_cr_wdata (driven by the core) and   //
// fp_done, fp_accepted, fp_unimp, fp_unsupp, fp_exc_req, fp_exc_vec,       //
// fp_dout, fp_cr_rdata, fp_fm_rdata (driven back), plus clk, nreset and    //
// fp_ce.                                                                   //
//                                                                          //
// TIED OFF, and each one is a recorded gap, not an oversight:              //
//   frestore_busy /      the $4160 BUSY frame, which needs the deferred    //
//   fstate_busy          exception path `pend_capture` is tied off for, so  //
//                        the unit can never be holding one (M10.7).        //
//   pend_capture         the FSAVE frame of a DEFERRED exception: M10.3    //
//                        delivers the exception itself, but the e1 state    //
//                        frame it would leave waits for FSAVE.             //
//--------------------------------------------------------------------------//

ap040_fpu u_fpu
(
	.clk(clk), .nreset(nreset), .ce(fp_ce),

	.req(fp_req), .op_class(fp_op_class), .opmode(fp_opmode),
	.src_fmt(fp_src_fmt), .src_r(fp_src_r), .dst_r(fp_dst_r), .din(fp_din),
	.done(fp_done), .accepted(fp_accepted),
	.unimp(fp_unimp), .unsupp(fp_unsupp),
	.exc_req(fp_exc_req), .exc_vec(fp_exc_vec), .dout(fp_dout),
	.fpcc(fp_fpcc),

	.cr_sel(fp_cr_sel), .cr_we(fp_cr_we), .cr_wdata(fp_cr_wdata), .cr_rdata(fp_cr_rdata),
	.bsun_req(fp_bsun_req), .bsun_enable(fp_bsun_en),

	.ia_we(fp_ia_we), .ia_wdata(fp_ia_wdata),

	.fm_sel(fp_fm_sel), .fm_we(fp_fm_we), .fm_wdata(fp_fm_wdata), .fm_rdata(fp_fm_rdata),

	.fpu_used(fp_used), .fstate_unimp(fp_st_unimp),
	.fstate_cmd1(fp_st_cmd1), .fstate_cmd3(fp_st_cmd3),
	.fstate_stag(fp_st_stag), .fstate_dtag(fp_st_dtag), .fstate_flags(fp_st_flags),
	.fstate_fpt(fp_st_fpt), .fstate_et(fp_st_et),
	.fsave_ack(fp_fsave_ack), .frestore_idle(fp_fridle), .frestore_unimp(fp_fr_unimp),
	.pend_capture(1'b0), .cur_vec(), .frestore_e1_pend(),
	.fstate_grs(fp_st_grs), .fstate_wbte15(fp_st_wbte15), .fstate_busy(),
	.fstate_wbt(), .fstate_fpiar_c(),
	.frestore_wbt(96'd0), .frestore_fpiar(32'd0), .frestore_busy(1'b0),
	.frestore_cmd1(fp_fr_cmd1), .frestore_cmd3(fp_fr_cmd3),
	.frestore_stag(fp_fr_stag), .frestore_dtag(fp_fr_dtag), .frestore_flags(fp_fr_flags),
	.frestore_fpt(fp_fr_fpt), .frestore_et(fp_fr_et),
	.frestore_grs(fp_fr_grs), .frestore_wbte15(fp_fr_wbte15),
	.fp_reset(fp_frst)
);
