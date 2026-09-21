#!/bin/sh
# AP040_PIPE self-test suite -- the pipelined core (rtl/ap040_pipe_core.v and
# its stage files).  Needs only iverilog.  Most benches poke their program
# straight into the L1 array (dut.u_l1.mem[...]) at time 0.
#
# The source list is rtl/ap040_pipe_pkg.sv (a package: compiled first) plus
# every rtl/ap040_*.v -- rtl_old/ is never needed.
#
# Minimig plan M1: the milestone-12 unit bench tb_ap040_pipe_l1_wbuf.v is
# retired with the one-entry write buffer it tested (ap040_pipe_l1.v was
# rewritten with byte-granular read/write ports; tb_ap040_pipe_l1_bytes.v
# tests those).
set -eu
cd "$(dirname "$0")"

RTL=../rtl
WORK=build
mkdir -p "$WORK"

SRC="$RTL/ap040_pipe_pkg.sv $(ls $RTL/ap040_*.v | tr '\n' ' ')"

# milestone benches (1-17)
TESTS="nop moveq add bra bcc bccw bccl scc dbcc move_mem move_disp jmp bsr jsr exc sup rts_rte addrerr"
# Minimig plan benches, by milestone
TESTS="$TESTS red_movew red_rte_fmt2 red_vbr red_aline_fline"               # M0 red legs, green since M1
TESTS="$TESTS ${PIPE_EXTRA_TESTS:-}"

echo "== compiling pipe benches =="
for t in $TESTS; do
	iverilog -g2012 -I "$RTL" -o "$WORK/tb_pipe_$t.vvp" "tb_ap040_pipe_$t.v" $SRC > "$WORK/tb_pipe_$t.clog" 2>&1 || {
		echo "  COMPILE-ERROR $t"; grep -v "sorry: constant selects" "$WORK/tb_pipe_$t.clog" | head -5; exit 1; }
done

echo "== running =="
fail=0
for t in $TESTS; do
	if timeout 600 vvp "$WORK/tb_pipe_$t.vvp" > "$WORK/pipe_$t.log" 2>&1 && grep -q "ALL TESTS PASSED" "$WORK/pipe_$t.log"; then
		echo "  pass  $t"
	else
		echo "  FAIL  $t  (see $WORK/pipe_$t.log)"
		fail=1
	fi
done

# program benches: pipe_asm/<name>.s + <name>.exp through tb_ap040_pipe_prog.v
# (needs vasmm68k_mot; the .exp files were made from a reference-core run
# with findings/ap040-pipelined/tests/mkprog.sh and reviewed)
if command -v vasmm68k_mot > /dev/null; then
	iverilog -g2012 -I "$RTL" -o "$WORK/tb_pipe_prog.vvp" tb_ap040_pipe_prog.v $SRC > "$WORK/tb_pipe_prog.clog" 2>&1 || {
		echo "  COMPILE-ERROR prog bench"; grep -v "constant selects" "$WORK/tb_pipe_prog.clog" | head -5; exit 1; }
	for s in pipe_asm/*.s; do
		n=$(basename "$s" .s)
		[ -f "pipe_asm/$n.exp" ] || continue
		( cd pipe_asm && vasmm68k_mot -Fbin -m68040 -no-opt -quiet -o "../$WORK/$n.bin" "$n.s" ) || { echo "  FAIL  prog:$n (assembler)"; fail=1; continue; }
		python3 bin2hex.py "$WORK/$n.bin" "$WORK/$n.hex"
		if timeout 600 vvp "$WORK/tb_pipe_prog.vvp" +prog="$WORK/$n.hex" +expect="pipe_asm/$n.exp" > "$WORK/prog_$n.log" 2>&1 &&
		   grep -q "ALL TESTS PASSED" "$WORK/prog_$n.log"; then
			echo "  pass  prog:$n"
		else
			echo "  FAIL  prog:$n  (see $WORK/prog_$n.log)"
			fail=1
		fi
	done
else
	echo "  (vasmm68k_mot not found: program benches skipped)"
fi

if [ $fail -eq 0 ]; then echo "AP040_PIPE: ALL TESTS PASSED"; else echo "AP040_PIPE: FAILURES"; exit 1; fi
