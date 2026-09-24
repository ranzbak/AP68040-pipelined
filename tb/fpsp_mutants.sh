#!/bin/bash
# fpsp_mutants.sh -- the named mutants of the 2026-09-24 FPSP work (plan M10
# remainder: the $4160 BUSY frame, the CU_SAVEPC=$FE resume, the datatype
# payloads).  Each one must be CAUGHT; they run in parallel (vvp is single
# threaded, every mutant has its own scratch tree).
#
#   AP040_PIPE=<this tree> bash tb/fpsp_mutants.sh [filter]
#
# Needs findings/ap040-pipelined/tests/mutants/run_mutant.sh (Paul's
# MinimigAGA_TC64 checkout).  The fpsp: kind additionally needs the relocated
# 68040.library (tb/build/fpsp040lib.bin, made by run_pipe_tests.sh).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
export AP040_PIPE=${AP040_PIPE:-$(cd "$HERE/.." && pwd)}
RM=${RUN_MUTANT:-$HERE/../../MinimigAGA_TC64/findings/ap040-pipelined/tests/mutants/run_mutant.sh}
OUT=${OUT:-$HERE/build/fpsp_mutants}
mkdir -p "$OUT"
F=${1:-}
run() {   # <name> <file> <sed> <bench>
	case "$1" in *$F*) ;; *) return ;; esac
	( sh "$RM" "$2" "$3" "$4" > "$OUT/$1.log" 2>&1; echo "$1 exit=$?" >> "$OUT/$1.log" ) &
}
E=ap040_ea_fetch.v
U=compat/ap040_fpu.v
# the core: FSAVE / FRESTORE of the BUSY frame
run BZ1 $E 's/fp_fn <= 5.d0; fp_bsy <= fp_st_busy;/fp_fn <= 5'"'"'d0; fp_bsy <= 1'"'"'b0;/'        fpr:fpureal_busy
run BZ2 $E 's/(fp_st_busy ? 32.d96 : 32.d48)/(fp_st_busy ? 32'"'"'d48 : 32'"'"'d48)/'               fpr:fpureal_busy
run BZ3 $E 's/(fp_bsy ? 32.d100 : 32.d52)/(fp_bsy ? 32'"'"'d52 : 32'"'"'d52)/'                      fpr:fpureal_busy
run BZ4 $E 's/rd_data == 32.h4130_0000 || rd_data == 32.h4160_0000/rd_data == 32'"'"'h4130_0000/'    fpr:fpureal_busy
run BZ5 $E 's/(fp_rs \&\& fp_frm \&\& fp_bsy \&\& fp_fr_resume \&\& !fp_done)/1'"'"'b0/'           fpr:fpureal_busy
run BZ6 $E 's/5.d2:  fr_cusave <= rd_data\[31:24\];/5'"'"'d2:  fr_cusave <= 8'"'"'d0;/'            fpr:fpureal_busy
run BZ7 $E 's/fr_et15 <= rd_data\[28\];/fr_et15 <= 1'"'"'b0;/'                                       fpr:fpureal_busy
run BZ8 $E 's/5.d10: fr_fpiar <= rd_data;/5'"'"'d10: fr_fpiar <= 32'"'"'d0;/'                      fpr:fpureal_busy
# the unit: the resume and the datatype payloads
run BU1 $U 's/assign frestore_resume = frestore_busy \&\&/assign frestore_resume = 1'"'"'b0 \&\& frestore_busy \&\&/' fpr:fpureal_busy
run BU2 $U 's/^\t\t\t\t\t\tif (!r_resume)$/\t\t\t\t\t\tif (1'"'"'b1)/'                                    fpr:fpureal_busy
run BU3 $U 's/sh_cnt <= restore_shift(frestore_et15, frestore_et\[94:80\]);/sh_cnt <= 7'"'"'d0;/'  fpr:fpureal_busy
run BU4 $U 's/{32.d0, din\[63:32\], din\[95:64\]}, 3.d0,$/96'"'"'d0, 3'"'"'d0,/'                     fpr:fpureal_busy
run BU5 $U 's/{r_din\[95\], 15.h3F80, 16.d0,/{r_din[95], r_din[94:80], 16'"'"'d0,/'                  fpr:fpureal_busy
run BU6 $U 's/fstate_fpiar_c <= ia_we ? ia_wdata : fpiar;/fstate_fpiar_c <= fpiar;/'                fpr:fpureal_busy
# the deferred exception's frame (compat: upstream t_fpu_frames.s, whose hex
# run_pipe_tests.sh leaves in tb/build/)
run PC1 $E 's/fp_pcap <= 1.b1;     \/\/ the unit/fp_pcap <= 1'"'"'b0;     \/\/ the unit/'                  compat:t_fpu_frames
run PC2 $E 's/wire        fp_pex     = fp_rs || (fp_sv \&\& fp_st_unimp);/wire        fp_pex     = fp_rs;/'  compat:t_fpu_frames
run PC3 $E 's/fp_pend <= fp_fr_e1pend \&\& !(fr_busy \&\& fp_fr_resume);/fp_pend <= 1'"'"'b0;/'          compat:t_fpu_frames
run PC4 $E 's/wire        fp_pex     = fp_rs || (fp_sv \&\& fp_st_unimp);/wire        fp_pex     = fp_sv \&\& fp_st_unimp;/' fpr:fpureal_busy
wait
grep -h 'MUTANT\|exit=' "$OUT"/*.log
