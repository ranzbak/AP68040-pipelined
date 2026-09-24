#!/bin/sh
# M14 mutant table for the instruction read path: each mutant is a one-line
# edit of a scratch copy of rtl/, then t_icache_pipe.s (and t_integer for the
# wedge mutant) on the compat bench.  A mutant is CAUGHT when the program
# does not print ALL TESTS PASSED.  Mutants run in parallel (vvp is single-
# threaded), each in its own directory under $OUT.
#   sh tb/perf/m14_mutants.sh [out-dir]      (ONLY_D=1: step 3's table only)
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$T/build/m14mut}
mkdir -p "$OUT"
PROG=$OUT/t_icache_pipe.hex
DPROG=$OUT/t_dcache_pipe.hex
vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$OUT/t_icache_pipe.bin" "$T/cache_asm/t_icache_pipe.s" &&
python3 "$T/bin2hex.py" "$OUT/t_icache_pipe.bin" "$PROG" || exit 1
vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$OUT/t_dcache_pipe.bin" "$T/cache_asm/t_dcache_pipe.s" &&
python3 "$T/bin2hex.py" "$OUT/t_dcache_pipe.bin" "$DPROG" || exit 1

run_one() {   # name file old new [program hex, default t_icache_pipe]
	n=$1; f=$2; old=$3; new=$4; prog=${5:-$PROG}
	d=$OUT/$n; mkdir -p "$d"
	git -C "$T/.." archive HEAD rtl | tar -x -C "$d"
	# the working tree's rtl (uncommitted M14 changes) over the archive
	cp -r "$T/../rtl/." "$d/rtl/"
	python3 - "$d/rtl/$f" "$old" "$new" <<'PY' || { echo "  $n: EDIT DID NOT APPLY"; return; }
import sys
p,old,new=sys.argv[1:4]; s=open(p).read()
# a name starting with A_ in the caller replaces every occurrence
if old.startswith('ALL:'):
    old=old[4:]
    if s.count(old)<1: sys.exit(1)
elif s.count(old)!=1: sys.exit(1)
open(p,'w').write(s.replace(old,new))
PY
	R=$d/rtl
	SRC="$R/ap040_pipe_pkg.sv $(ls $R/ap040_*.v | tr '\n' ' ') $(ls $R/compat/*.v | tr '\n' ' ') $R/compat/primitives/dpram.v"
	iverilog -g2012 -I "$R" -I "$R/compat" -o "$d/tb.vvp" "$T/tb_ap040_pipe_compat.v" $SRC > "$d/clog" 2>&1 || { echo "  $n: MUTANT DOES NOT COMPILE"; return; }
	timeout 900 vvp "$d/tb.vvp" +prog="$prog" +timeout=3000000 > "$d/log" 2>&1
	if grep -q "ALL TESTS PASSED" "$d/log"; then echo "  $n: SURVIVED"
	else echo "  $n: caught ($(grep -m1 -E 'FAIL|timeout|TIMEOUT' "$d/log" | cut -c1-100))"; fi
}

if [ -z "${ONLY_D:-}" ]; then   # ONLY_D=1: the data-path table alone
run_one M1_data_copy_not_written compat/ap040_cache.v \
 "if (ce & cd_we[0] & cd_widx[8]) idat0" "if (1'b0) idat0" &
run_one M2_valid_not_cleared_by_sweep compat/ap040_cache.v \
 "if (ce & tag_we & tag_widx[6]) iv[tag_widx[5:0]] <= tag_wdat[91:88];" \
 "if (ce & tag_we & tag_widx[6] & (cst == C_TAGW)) iv[tag_widx[5:0]] <= tag_wdat[91:88];" &
run_one M3_IE_ignored compat/ap040_pipe_tg68k_compat.v \
 "wire ia_ok    = ifp_ie_q && ifp_tok" "wire ia_ok    = ifp_tok" &
run_one M4_CM_inhibit_ignored compat/ap040_pipe_tg68k_compat.v \
 "ifp_tok && !ifp_tci &&" "ifp_tok &&" &
run_one M5_translation_ignored compat/ap040_mmu.v \
 "assign ifp_pa = (!i_tce || i_ttr) ? i_la :" "assign ifp_pa = 1'b1 ? i_la :" &
run_one M6_miss_not_reissued ap040_pipe_core.v \
 "wire       miss   = ifp_look && !ifp_hit;" "wire       miss   = 1'b0;" &
run_one M7_portB_invalidate_not_mirrored compat/ap040_cache.v \
 "if (inv_wren & inv_idx[6])     iv[inv_idx[5:0]]  <= 4'd0;" "" &
run_one M8_fast_word_fetch_misaligned ap040_pipe_core.v \
 "(ifp_l ? ifp_data : {ifp_data[15:0], 16'h4E71})" "ifp_data" &
# step 2: the instruction-side ATC copy (ap040_mmu.v g_ifp)
run_one M9_iatc_valid_ignored compat/ap040_mmu.v \
 "ALL:atc_v[{1'b1, i_set, 2'd" "1'b1 | atc_v[{1'b1, i_set, 2'd" &
# (not a mutant: `!(!i_sup && is_s)` cannot be observed -- the ATC tag
#  carries the S bit, and a walk that finds S set for a user access faults
#  without filling (W_DFLT), so no user-tagged entry has S set; it stays as
#  the same defence the request port's atc_fault keeps)
run_one M11_iatc_copy_not_filled compat/ap040_mmu.v \
 "if (fill_we && fill_row[4]) iatc" "if (1'b0) iatc" &
wait
fi
# step 3: the data read path (t_dcache_pipe.s)
run_one D1_snoop_not_mirrored compat/ap040_cache.v \
 "if (w_inv) dv[inv_idx[5:0]]  <= 4'd0;" "" "$DPROG" &
run_one D2_store_order_ignored ap040_pipe_core.v \
 "assign d_rd_fast = dfp_look && dfp_q1 && st_quiet && dfp_hit;" "assign d_rd_fast = dfp_look && dfp_hit;" "$DPROG" &
run_one D3_store_order_launch_clock_only ap040_pipe_core.v \
 "assign d_rd_fast = dfp_look && dfp_q1 && st_quiet && dfp_hit;" "assign d_rd_fast = dfp_look && dfp_q1 && dfp_hit;" "$DPROG" &
run_one D4_DE_ignored compat/ap040_pipe_tg68k_compat.v \
 "else if (ce_core) dfp_ok_q <= dfp_req && cacr_out[31] &&" "else if (ce_core) dfp_ok_q <= dfp_req &&" "$DPROG" &
run_one D5_CM_inhibit_ignored compat/ap040_pipe_tg68k_compat.v \
 "dfp_ok_q && dfp_tok && !dfp_tci &&" "dfp_ok_q && dfp_tok &&" "$DPROG" &
run_one D6_datc_valid_ignored compat/ap040_mmu.v \
 "ALL:atc_v[{1'b0, d_set, 2'd" "1'b1 | atc_v[{1'b0, d_set, 2'd" "$DPROG" &
run_one D7_translation_ignored compat/ap040_mmu.v \
 "assign dfp_pa = (!d_tce || d_ttr) ? d_la :" "assign dfp_pa = 1'b1 ? d_la :" "$DPROG" &
# (not a mutant: D8, the collision terms `!g_col && !d_busy_now`, cannot be
#  observed -- a launch-edge tag write is covered by the fill mask's
#  previous-clock term, a store merge by the store-order rule (the merging
#  store is still in WB in the launch clock), and a snoop by reading dv in
#  the answer clock; the terms stay as defence)
wait
run_one D9_merge_not_mirrored compat/ap040_cache.v \
 "if (ce & cd_we[0] & !cd_widx[8]) ddat0" "if (ce & cd_we[0] & !cd_widx[8] & !st_merge) ddat0" "$DPROG" &
run_one D10_misaligned_served compat/ap040_pipe_tg68k_compat.v \
 "(dfp_size == \`AP040_SZ_L && dfp_addr[1:0] == 2'b00));" "(dfp_size == \`AP040_SZ_L));" "$DPROG" &
wait
