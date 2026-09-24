#!/bin/sh
# M14 mutant table for the instruction read path: each mutant is a one-line
# edit of a scratch copy of rtl/, then t_icache_pipe.s (and t_integer for the
# wedge mutant) on the compat bench.  A mutant is CAUGHT when the program
# does not print ALL TESTS PASSED.  Mutants run in parallel (vvp is single-
# threaded), each in its own directory under $OUT.
#   sh tb/perf/m14_mutants.sh [out-dir]
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$T/build/m14mut}
mkdir -p "$OUT"
PROG=$OUT/t_icache_pipe.hex
vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$OUT/t_icache_pipe.bin" "$T/cache_asm/t_icache_pipe.s" &&
python3 "$T/bin2hex.py" "$OUT/t_icache_pipe.bin" "$PROG" || exit 1

run_one() {   # name file old new
	n=$1; f=$2; old=$3; new=$4
	d=$OUT/$n; mkdir -p "$d"
	git -C "$T/.." archive HEAD rtl | tar -x -C "$d"
	# the working tree's rtl (uncommitted M14 changes) over the archive
	cp -r "$T/../rtl/." "$d/rtl/"
	python3 - "$d/rtl/$f" "$old" "$new" <<'PY' || { echo "  $n: EDIT DID NOT APPLY"; return; }
import sys
p,old,new=sys.argv[1:4]; s=open(p).read()
if s.count(old)!=1: sys.exit(1)
open(p,'w').write(s.replace(old,new))
PY
	R=$d/rtl
	SRC="$R/ap040_pipe_pkg.sv $(ls $R/ap040_*.v | tr '\n' ' ') $(ls $R/compat/*.v | tr '\n' ' ') $R/compat/primitives/dpram.v"
	iverilog -g2012 -I "$R" -I "$R/compat" -o "$d/tb.vvp" "$T/tb_ap040_pipe_compat.v" $SRC > "$d/clog" 2>&1 || { echo "  $n: MUTANT DOES NOT COMPILE"; return; }
	timeout 900 vvp "$d/tb.vvp" +prog="$PROG" +timeout=3000000 > "$d/log" 2>&1
	if grep -q "ALL TESTS PASSED" "$d/log"; then echo "  $n: SURVIVED"
	else echo "  $n: caught ($(grep -m1 -E 'FAIL|timeout|TIMEOUT' "$d/log" | cut -c1-100))"; fi
}

run_one M1_data_copy_not_written compat/ap040_cache.v \
 "if (ce & cd_we[0] & cd_widx[8]) idat0" "if (1'b0) idat0" &
run_one M2_valid_not_cleared_by_sweep compat/ap040_cache.v \
 "if (ce & tag_we & tag_widx[6]) iv[tag_widx[5:0]] <= tag_wdat[91:88];" \
 "if (ce & tag_we & tag_widx[6] & (cst == C_TAGW)) iv[tag_widx[5:0]] <= tag_wdat[91:88];" &
run_one M3_IE_ignored compat/ap040_pipe_tg68k_compat.v \
 "wire ia_ok    = cacr_out[15] && " "wire ia_ok    = 1'b1 && " &
run_one M4_ITT_CM_ignored compat/ap040_pipe_tg68k_compat.v \
 "&& !(ia_ttr && ia_ci) &&" "&&" &
run_one M5_TC_ignored compat/ap040_pipe_tg68k_compat.v \
 "(!ia_tc || ia_ttr) &&" "" &
run_one M6_miss_not_reissued ap040_pipe_core.v \
 "if (ifp_look && !ifp_hit) ifp_mreq <= 1'b1;" "" &
run_one M7_portB_invalidate_not_mirrored compat/ap040_cache.v \
 "if (inv_wren & inv_idx[6])     iv[inv_idx[5:0]]  <= 4'd0;" "" &
run_one M8_fast_word_fetch_misaligned ap040_pipe_core.v \
 "(ifp_l ? ifp_data : {ifp_data[15:0], 16'h4E71})" "ifp_data" &
wait
