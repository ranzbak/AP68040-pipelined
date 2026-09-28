#!/bin/bash
# Store buffer mutant table (findings/storebuf/plan.md): each mutant is a
# one-line edit of a scratch copy of rtl/ (the working tree's), built with
# STORE_BUF = 1, then run on the program that must catch it -- a pipe_asm
# program on the bus bench (profile 1) or a compat program.  A mutant is
# CAUGHT when the run does not print ALL TESTS PASSED.  Mutants run in
# parallel (vvp is single-threaded), each in its own directory under $OUT.
#   bash tb/perf/sb_mutants.sh [out-dir]
set -u
T=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$T/build/sbmut}
mkdir -p "$OUT"
AP040_REF=${AP040_REF:-/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/lib/AP68040}

asm() {   # name dir -> $OUT/name.hex
	( cd "$2" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "$OUT/$1.bin" "$1.s" ) &&
	python3 "$T/bin2hex.py" "$OUT/$1.bin" "$OUT/$1.hex"
}
for p in sb_raw sb_order sb_serialize sb_lateberr nop_sync; do asm $p "$T/pipe_asm" || exit 1; done
asm t_sbuf_pipe "$T/cache_asm" || exit 1
asm t_dcache_pipe "$T/cache_asm" || exit 1
python3 "$T/mk_tmmu.py" "$AP040_REF/tb/asm/t_mmu.s" m9s > "$OUT/t_mmu_m9s.s" &&
( cd "$OUT" && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o t_mmu_m9s.bin t_mmu_m9s.s ) &&
python3 "$T/bin2hex.py" "$OUT/t_mmu_m9s.bin" "$OUT/t_mmu_m9s.hex" || exit 1

run_one() {   # name file old new bench(prog|compat) program
	n=$1; f=$2; old=$3; new=$4; b=$5; prog=$6
	d=$OUT/$n; rm -rf "$d"; mkdir -p "$d"
	cp -r "$T/../rtl" "$d/rtl"
	python3 - "$d/rtl/$f" "$old" "$new" <<'PY' || { echo "  $n: EDIT DID NOT APPLY"; return; }
import sys
p,old,new=sys.argv[1:4]; s=open(p).read()
if s.count(old)!=1: sys.exit(1)
open(p,'w').write(s.replace(old,new))
PY
	R=$d/rtl
	SRC="$R/ap040_pipe_pkg.sv $(ls $R/ap040_*.v | tr '\n' ' ')"
	if [ "$b" = prog ]; then
		iverilog -g2012 -DSTORE_BUF=1 -DBUS_MODE -I "$R" -o "$d/tb.vvp" "$T/tb_ap040_pipe_prog.v" "$T/tb_sb_check.v" $SRC > "$d/clog" 2>&1 ||
			{ echo "  $n: MUTANT DOES NOT COMPILE"; return; }
		cyc=$(sed -n 's/^; diff:.*--cycles \([0-9]*\).*/\1/p' "$T/pipe_asm/$prog.s" | head -1)
		timeout 900 vvp "$d/tb.vvp" +prog="$OUT/$prog.hex" +expect="$T/pipe_asm/$prog.exp" +prof=1 +cycles=$(( ${cyc:-20000} * 8 )) > "$d/log" 2>&1
	else
		SRC="$SRC $(ls $R/compat/*.v | tr '\n' ' ') $R/compat/primitives/dpram.v"
		iverilog -g2012 -DSTORE_BUF=1 -I "$R" -I "$R/compat" -o "$d/tb.vvp" "$T/tb_ap040_pipe_compat.v" "$T/tb_sb_check.v" $SRC > "$d/clog" 2>&1 ||
			{ echo "  $n: MUTANT DOES NOT COMPILE"; return; }
		timeout 1800 vvp "$d/tb.vvp" +prog="$OUT/$prog.hex" +timeout=3000000 > "$d/log" 2>&1
	fi
	if grep -q "ALL TESTS PASSED" "$d/log"; then echo "  $n ($prog): SURVIVED"
	else echo "  $n ($prog): caught ($(grep -m1 -E 'FAIL|timeout|TIMEOUT' "$d/log" | cut -c1-110))"; fi
}

echo "== store buffer mutants (STORE_BUF = 1)"
# a slot read goes with posted stores still in the FIFO
run_one rd_nodrain ap040_pipe_bcu.v \
	"wire go_rd   = idle && !sp_on && (sb_cnt == 0) && !st_v" \
	"wire go_rd   = idle && !sp_on && !st_v" prog sb_raw &
# a synchronous store overtakes the FIFO
run_one sync_overtake ap040_pipe_bcu.v \
	"!((DONE_REG != 0) && st_done_q) && (sb_cnt == 0);" \
	"!((DONE_REG != 0) && st_done_q);" prog sb_order &
# the data read path answers with posted stores in the FIFO
run_one fast_nodrain ap040_pipe_core.v \
	"!((STORE_BUF != 0) && sb_busy);" \
	"1'b1;" compat t_sbuf_pipe &
# a serialising instruction does not wait for the FIFO
run_one ser_nodrain ap040_pipe_core.v \
	"wire older_busy  = eaf_valid || exe_valid || sb_busy;" \
	"wire older_busy  = eaf_valid || exe_valid || (sb_busy && STORE_BUF == 0);" prog sb_serialize &
wait
# ... nor a MOVEC to TC (the same mutant, the translation program)
run_one ser_nodrain_tc ap040_pipe_core.v \
	"wire older_busy  = eaf_valid || exe_valid || sb_busy;" \
	"wire older_busy  = eaf_valid || exe_valid || (sb_busy && STORE_BUF == 0);" compat t_sbuf_pipe &
# a posted store's bus error does not halt
run_one no_halt ap040_pipe_core.v \
	".st_fatal((STORE_BUF == 1) && bus_st_err)," \
	".st_fatal(1'b0)," prog sb_lateberr &
# posting with translation on (a write-protect fault would be lost)
run_one post_tc_on ap040_pipe_core.v \
	"!tc[15] && !(dtt0[15] && dtt0[2])" \
	"!(dtt0[15] && dtt0[2])" compat t_mmu_m9s &
# the FIFO drains its NEWEST entry
run_one fifo_lifo ap040_pipe_bcu.v \
	"a = go_fifo ? sb_a[sb_rp] : st_addr;" \
	"a = go_fifo ? sb_a[sb_wp - 1'b1] : st_addr;" prog sb_raw &
wait
