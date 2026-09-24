// perf_probe.vh -- a cycle-accounting probe for the pipelined core, for the
// performance measurement (Minimig plan M11, 2026-09-24: SysInfo SPEED).
//
// Include it inside a module after defining
//   PP_W    hierarchical path of ap040_pipe_tg68k_compat (the wrapper)
//   PP_EN   an expression: count while it is true (the measured window)
//   PP_TAG  a string printed with the report
// e.g. tb/perf/tb_perf_compat.v and findings/ap040-pipelined/tests/perf/.
//
// Every rising edge of the core's clock inside the window is put in exactly
// ONE bucket, oldest cause first:
//
//   FZ_*   the core's clock enable was LOW.  On the board (rtl/soc/TG68K.vhd
//          bus_release) and in the compat bench (clkena_in = idle | ready) the
//          whole core, MMU and cache are frozen while an access on the
//          wrapper's master channel (m_*) is outstanding.  Split by what the
//          channel carries: a store (write-through / posted-store drain), a
//          cache line fill (I or D), or anything else (uncached, I/O).
//   RET    WB retired a micro-op.
//   ST     WB holds a store the MMU/cache has not acknowledged yet.
//   EX     EX is busy with a multi-clock operation (MUL/DIV, ...).
//   XFER   the oldest instruction is in EA-fetch's output register and moves
//          into EX this clock: a pipeline bubble in transit.
//   RD     EA-fetch is waiting for its data read (queued in the BCU slot or
//          on the port).
//   EAF    EA-fetch holds an instruction for any other reason (a multi-step
//          instruction, an interlock, serialisation, the held redirect).
//   FE     the oldest instruction is in EA-calc/ID (front-end transit/stall).
//   Q      only IF's queue holds anything (ID gathering an extension word).
//   EMPTY_F  nothing in the pipeline, IF's fetch is on the port;
//   EMPTY_D  nothing in the pipeline, IF wants the port and the port is
//            busy with a data read or a store (the M14 conflict);
//   EMPTY_I  nothing in the pipeline and IF is not asking (held after a
//            redirect, or waiting for the grant's answer).
//
// Overlaid (not exclusive) counters: redirects by source, port transfers by
// kind, instructions (WB's last micro-op) and the clocks from each redirect
// to the next retirement (the refill cost).

integer pp_cyc, pp_ins, pp_uop;
integer pp_fz_st, pp_fz_fi, pp_fz_fd, pp_fz_ot;
integer pp_ret, pp_st, pp_ex, pp_xfer, pp_rd, pp_eaf, pp_fe, pp_q, pp_ef, pp_ed, pp_ei;
integer pp_r_id, pp_r_eac, pp_r_eaf, pp_r_ex, pp_r_smc, pp_refill;
integer pp_t_if, pp_t_rd, pp_t_st, pp_m_rd, pp_m_wr, pp_m_fill;
integer pp_p_busy, pp_p_gap, pp_p_idle;
reg     pp_on, pp_in_refill;
reg     pp_m_req_d, pp_ack_d;
reg [3:0] pp_cst_d;

localparam [3:0] PP_C_FILL = 4'd4;          // ap040_cache.v C_FILL
localparam [1:0] PP_K_RD = 2'd1, PP_K_IF = 2'd2;

task pp_clear;
	begin
		pp_cyc = 0; pp_ins = 0; pp_uop = 0;
		pp_fz_st = 0; pp_fz_fi = 0; pp_fz_fd = 0; pp_fz_ot = 0;
		pp_ret = 0; pp_st = 0; pp_ex = 0; pp_xfer = 0; pp_rd = 0; pp_eaf = 0; pp_fe = 0; pp_q = 0;
		pp_ef = 0; pp_ed = 0; pp_ei = 0;
		pp_r_id = 0; pp_r_eac = 0; pp_r_eaf = 0; pp_r_ex = 0; pp_r_smc = 0; pp_refill = 0;
		pp_t_if = 0; pp_t_rd = 0; pp_t_st = 0; pp_m_rd = 0; pp_m_wr = 0; pp_m_fill = 0;
		pp_in_refill = 0;
		pp_p_busy = 0; pp_p_gap = 0; pp_p_idle = 0;
	end
endtask

function real pp_pc(input integer n);
	pp_pc = (pp_cyc == 0) ? 0.0 : 100.0 * n / pp_cyc;
endfunction

task pp_report;
	begin
		$display("PERF %0s: %0d clocks, %0d instructions (%0d micro-ops), CPI %0.3f",
		         `PP_TAG, pp_cyc, pp_ins, pp_uop, (pp_ins == 0) ? 0.0 : 1.0 * pp_cyc / pp_ins);
		$display("PERF   frozen (enable low, m_* busy): store %0d (%0.1f%%)  I-fill %0d (%0.1f%%)  D-fill %0d (%0.1f%%)  other %0d (%0.1f%%)",
		         pp_fz_st, pp_pc(pp_fz_st), pp_fz_fi, pp_pc(pp_fz_fi), pp_fz_fd, pp_pc(pp_fz_fd), pp_fz_ot, pp_pc(pp_fz_ot));
		$display("PERF   retire %0d (%0.1f%%)  store-hold %0d (%0.1f%%)  EX busy %0d (%0.1f%%)  EAF->EX transit %0d (%0.1f%%)",
		         pp_ret, pp_pc(pp_ret), pp_st, pp_pc(pp_st), pp_ex, pp_pc(pp_ex), pp_xfer, pp_pc(pp_xfer));
		$display("PERF   data-read wait %0d (%0.1f%%)  EA-fetch other %0d (%0.1f%%)  EA-calc/ID %0d (%0.1f%%)  queue-only %0d (%0.1f%%)",
		         pp_rd, pp_pc(pp_rd), pp_eaf, pp_pc(pp_eaf), pp_fe, pp_pc(pp_fe), pp_q, pp_pc(pp_q));
		$display("PERF   empty: fetch on port %0d (%0.1f%%)  fetch denied %0d (%0.1f%%)  IF idle %0d (%0.1f%%)",
		         pp_ef, pp_pc(pp_ef), pp_ed, pp_pc(pp_ed), pp_ei, pp_pc(pp_ei));
		$display("PERF   redirects: ID %0d  EA-calc %0d  EA-fetch %0d  EX %0d  SMC %0d;  redirect-to-retire clocks %0d (%0.1f%%)",
		         pp_r_id, pp_r_eac, pp_r_eaf, pp_r_ex, pp_r_smc, pp_refill, pp_pc(pp_refill));
		$display("PERF   core port transfers: fetch %0d  read %0d  store %0d;  m_* channel: reads %0d  writes %0d  line fills %0d",
		         pp_t_if, pp_t_rd, pp_t_st, pp_m_rd, pp_m_wr, pp_m_fill);
		$display("PERF   core port (enabled clocks): request up %0d (%0.1f%%, %0.2f per transfer)  ack-clock gap %0d  idle %0d",
		         pp_p_busy, pp_pc(pp_p_busy), (pp_t_if + pp_t_rd + pp_t_st == 0) ? 0.0 : 1.0 * pp_p_busy / (pp_t_if + pp_t_rd + pp_t_st),
		         pp_p_gap, pp_p_idle);
	end
endtask

initial begin pp_clear; pp_on = 0; pp_m_req_d = 0; pp_cst_d = 0; pp_ack_d = 0; end

always @(posedge `PP_W.clk) begin
	if ((`PP_EN) && !pp_on) begin pp_clear; pp_on = 1; end
	else if (!(`PP_EN) && pp_on) begin pp_on = 0; pp_report; end
	if (pp_on) begin
		pp_cyc = pp_cyc + 1;
		// channel transactions (edge counted, whatever the enable)
		if (`PP_W.m_req && !pp_m_req_d) begin
			if (`PP_W.m_write) pp_m_wr = pp_m_wr + 1; else pp_m_rd = pp_m_rd + 1;
		end
		if (`PP_W.g_cache.cache.cst == PP_C_FILL && pp_cst_d != PP_C_FILL) pp_m_fill = pp_m_fill + 1;
		if (!`PP_W.ce_core) begin
			if (`PP_W.m_write) pp_fz_st = pp_fz_st + 1;
			else if (`PP_W.g_cache.cache.cst == PP_C_FILL) begin
				if (`PP_W.m_instr) pp_fz_fi = pp_fz_fi + 1; else pp_fz_fd = pp_fz_fd + 1;
			end
			else pp_fz_ot = pp_fz_ot + 1;
		end else begin
			// events
			if (`PP_W.core.wb_smc) pp_r_smc = pp_r_smc + 1;
			else if (`PP_W.core.ex_redirect) pp_r_ex = pp_r_ex + 1;
			else if (`PP_W.core.eaf_redir_v) pp_r_eaf = pp_r_eaf + 1;
			else if (`PP_W.core.eac_redir_v) pp_r_eac = pp_r_eac + 1;
			else if (`PP_W.core.id_redirect_valid) pp_r_id = pp_r_id + 1;
			if (`PP_W.core.g_bus.u_bcu.go_if) pp_t_if = pp_t_if + 1;
			if (`PP_W.core.g_bus.u_bcu.go_rd) pp_t_rd = pp_t_rd + 1;
			if (`PP_W.core.g_bus.u_bcu.go_st) pp_t_st = pp_t_st + 1;
			if (`PP_W.core.u_wb.wb_valid) pp_ins = pp_ins + 1;
			if (`PP_W.core.retire) pp_uop = pp_uop + 1;
			// the port: a request up, the clock after an acknowledge (the BCU
			// never starts a new transfer in it), or idle
			if (`PP_W.core.g_bus.u_bcu.mem_req) pp_p_busy = pp_p_busy + 1;
			else if (pp_ack_d) pp_p_gap = pp_p_gap + 1;
			else pp_p_idle = pp_p_idle + 1;
			if (pp_in_refill) pp_refill = pp_refill + 1;
			if (`PP_W.core.retire) pp_in_refill = 0;
			if (`PP_W.core.redirect_valid) pp_in_refill = 1;
			// the one bucket
			if (`PP_W.core.retire) pp_ret = pp_ret + 1;
			else if (`PP_W.core.exe_valid) pp_st = pp_st + 1;
			else if (`PP_W.core.eaf_valid) begin
				if (`PP_W.core.ex_stall) pp_ex = pp_ex + 1; else pp_xfer = pp_xfer + 1;
			end
			else if (`PP_W.core.eac_valid) begin
				if (`PP_W.core.g_bus.u_bcu.dq_v || `PP_W.core.d_rd_req ||
				    (`PP_W.core.g_bus.u_bcu.mem_req && `PP_W.core.g_bus.u_bcu.kind == PP_K_RD))
					pp_rd = pp_rd + 1;
				else pp_eaf = pp_eaf + 1;
			end
			else if (`PP_W.core.id_valid) pp_fe = pp_fe + 1;
			else if (`PP_W.core.q_v0) pp_q = pp_q + 1;
			else if (`PP_W.core.g_bus.u_bcu.mem_req && `PP_W.core.g_bus.u_bcu.kind == PP_K_IF) pp_ef = pp_ef + 1;
			else if (`PP_W.core.f_req && !`PP_W.core.f_gnt) pp_ed = pp_ed + 1;
			else pp_ei = pp_ei + 1;
		end
		pp_m_req_d = `PP_W.m_req;
		if (`PP_W.ce_core) pp_ack_d = `PP_W.core.g_bus.u_bcu.done;
		pp_cst_d   = `PP_W.g_cache.cache.cst;
	end
end
