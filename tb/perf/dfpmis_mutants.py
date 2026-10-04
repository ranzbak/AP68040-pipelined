#!/usr/bin/env python3
"""dfpmis_mutants.py [-j N] [-o out-dir] [names...]: the misaligned-read path's
mutant table (findings/loadstore/plan.md step 3, AP040_DFP_MIS).  Each mutant
is a one- or two-line edit of a scratch copy of rtl/, built on the compat
bench with the board switches plus DFP_MIS=1 and the white-box checker
tb_dfpmis_check.v, and run on cache_asm/t_dfpmis_pipe.s.  A mutant is CAUGHT
when the run does not print ALL TESTS PASSED (the program's value checks, the
store-order checker or the collision checker).  Runs -j mutants in parallel
(vvp is single-threaded; default 3)."""
import os, subprocess, sys, shutil
from concurrent.futures import ThreadPoolExecutor

T = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))     # tb/
R0 = os.path.join(os.path.dirname(T), "rtl")
DEFS = "-DSTORE_BUF=1 -DFWD=1 -DRAS=1 -DPRECISE=1 -DSB_MMU=1 -DLDX=1 -DBTFN=1 -DDFP_MIS=1".split()

# name: what it breaks, [(file, old, new), ...]
MUT = {
 "m1_tag2": ("the second lookup's tag compare removed (any valid line in the set will do)", [
    ("compat/ap040_cache.v", "\tassign e0 = dvv[0] && (g_m2 ? m0 : t0);", "\tassign e0 = dvv[0] && (g_m2 ? 1'b1 : t0);")]),
 "m2_page": ("a page-crossing read allowed (the cache's and the wrapper's rule)", [
    ("compat/ap040_cache.v", "\twire        two_in = (DFP_MIS != 0) && (dfp_addr[11:2] != 10'h3FF) &&", "\twire        two_in = (DFP_MIS != 0) &&"),
    ("compat/ap040_pipe_tg68k_compat.v", "\t\t\tdfp_mok_q <= (AP040_DFP_MIS != 0) && dfp_req && cacr_out[31] && (dfp_addr[11:2] != 10'h3FF) &&",
                                         "\t\t\tdfp_mok_q <= (AP040_DFP_MIS != 0) && dfp_req && cacr_out[31] &&")]),
 "m3_snoop": ("a write (snoop) landing on the first longword's set after its lookup ignored", [
    ("compat/ap040_cache.v", "\twire       h1_ok       = (DFP_MIS != 0) && g_h1 && !d1_busy &&", "\twire       h1_ok       = (DFP_MIS != 0) && g_h1 && 1'b1 &&"),
    ("compat/ap040_cache.v", "\t                         (|(vb[{1'b0, g_set1}] & ~dmask1_now & ~dmask1_prev & g_way1));", "\t                         1'b1;")]),
 "m3b_snoop2": ("a write landing on the second longword's set in the answer clock ignored", [
    ("compat/ap040_cache.v", "\tassign thit_now = (e0 | e1 | e2 | e3) && !g_col && !d_busy_now &&", "\tassign thit_now = (e0 | e1 | e2 | e3) && !g_col && (g_m2 || !d_busy_now) &&")]),
 "m3c_col2": ("a write landing on the second longword's set in the edge that reads it ignored", [
    ("compat/ap040_cache.v", "\tassign thit_now = (e0 | e1 | e2 | e3) && !g_col && !d_busy_now &&", "\tassign thit_now = (e0 | e1 | e2 | e3) && (g_m2 || !g_col) && !d_busy_now &&")]),
 "m4_store": ("a store in flight (EX, WB, the FIFO) ignored by the hold decision", [
    ("ap040_pipe_core.v", "\t\tassign d_rd_hold = (DFP_MIS != 0) && dfp_look && dfp_q1 && st_quiet_a && dfp_two &&", "\t\tassign d_rd_hold = (DFP_MIS != 0) && dfp_look && dfp_two &&"),
    ("ap040_pipe_core.v", "\t\t                   !((STORE_BUF != 0) && sb_ovl) && !d_rd_fwd;", "\t\t                   !d_rd_fwd;")]),
 "m5_carry": ("the second longword's tag without the carry at the 1K bank end", [
    ("compat/ap040_cache.v", "\t\t\t\tg_ptag2 <= dfp_ptag + {21'd0, (g_idx2 == 8'd0)};", "\t\t\t\tg_ptag2 <= dfp_ptag;")]),
 "m6_hold": ("the slot read not held: it goes out on the port in the second clock", [
    ("ap040_pipe_bcu.v", "dq_v && !rd_fast && !rd_fwd && !rd_hold;", "dq_v && !rd_fast && !rd_fwd;")]),
 "m7_tci": ("the cache-inhibit / translation / window qualification dropped from the second clock", [
    ("compat/ap040_pipe_tg68k_compat.v", "\tassign dfp_two = IFP_ON && dfp_mok_q && da_ok && dfp_thit && dfp_two_c;", "\tassign dfp_two = IFP_ON && dfp_mok_q && dfp_thit && dfp_two_c;")]),
 "m8_h1": ("the first longword's verdict not kept (the second clock trusts the first blindly)", [
    ("compat/ap040_cache.v", "\t\t\t\tg_h1    <= thit_now;", "\t\t\t\tg_h1    <= 1'b1;")]),
 "m9_ldx": ("(informational) a two-longword read dispatched late (LDX) after all", [
    ("ap040_ea_fetch.v", "               rd_pend && !rd_ack && !rd_drop && !ldx_pend && !vdep && !ldx_mis_q &&", "               rd_pend && !rd_ack && !rd_drop && !ldx_pend && !vdep &&")]),
 "m10_win": ("the operand assembled from the wrong half (a torn window)", [
    ("compat/ap040_cache.v", "\t\t\t\t\t2'd2: lw_extract2 = {a[15:0], w1[31:16]};", "\t\t\t\t\t2'd2: lw_extract2 = {a[15:0], a[31:16]};")]),
 "m11_m2c": ("the wrapper answers the second clock without its own qualification flop", [
    ("compat/ap040_pipe_tg68k_compat.v", "\tassign dfp_hit = IFP_ON && dfp_thit && ((dfp_ok_q && da_ok) || dfp_m2c_q);", "\tassign dfp_hit = IFP_ON && dfp_thit && ((dfp_ok_q && da_ok) || (dfp_mok_q && da_ok) || dfp_m2c_q);")]),
}

def run(name, out):
    what, edits = MUT[name]
    d = os.path.join(out, name)
    shutil.rmtree(d, ignore_errors=True)
    rtl = os.path.join(d, "rtl")
    shutil.copytree(R0, rtl)
    for f, old, new in edits:
        p = os.path.join(rtl, f)
        s = open(p).read()
        if s.count(old) != 1:
            return f"  {name}: EDIT DID NOT APPLY ({f}: {s.count(old)} matches)"
        open(p, "w").write(s.replace(old, new))
    src = [os.path.join(rtl, "ap040_pipe_pkg.sv")]
    src += sorted(os.path.join(rtl, x) for x in os.listdir(rtl) if x.startswith("ap040_") and x.endswith(".v"))
    src += sorted(os.path.join(rtl, "compat", x) for x in os.listdir(os.path.join(rtl, "compat")) if x.endswith(".v"))
    src += [os.path.join(rtl, "compat", "primitives", "dpram.v")]
    vvp = os.path.join(d, "tb.vvp")
    cmd = ["iverilog", "-g2012"] + DEFS + ["-I", rtl, "-I", os.path.join(rtl, "compat"), "-o", vvp,
           os.path.join(T, "tb_ap040_pipe_compat.v"), os.path.join(T, "tb_sb_check.v"), os.path.join(T, "tb_dfpmis_check.v")] + src
    with open(os.path.join(d, "clog"), "w") as cl:
        if subprocess.run(cmd, stdout=cl, stderr=subprocess.STDOUT).returncode != 0:
            return f"  {name}: MUTANT DOES NOT COMPILE"
    with open(os.path.join(d, "log"), "w") as lg:
        subprocess.run(["timeout", "3000", "vvp", vvp, "+prog=" + os.path.join(out, "t_dfpmis_pipe.hex"), "+timeout=3000000"],
                       stdout=lg, stderr=subprocess.STDOUT)
    log = open(os.path.join(d, "log")).read().splitlines()
    chk = next((l for l in log if "DFPMIS-CHECK" in l), "")
    if any("ALL TESTS PASSED" in l for l in log):
        return f"  {name}: SURVIVED -- {what}\n      {chk}"
    why = next((l for l in log if "FAIL" in l), "(no FAIL line: timeout?)")
    return f"  {name}: caught -- {what}\n      {why[:120]}"

def main():
    a = sys.argv[1:]; j = 3; out = os.path.join(T, "build", "dfpmut")
    while a and a[0].startswith("-"):
        if a[0] == "-j": j = int(a[1]); a = a[2:]
        elif a[0] == "-o": out = a[1]; a = a[2:]
        else: sys.exit("bad option " + a[0])
    names = a or list(MUT)
    os.makedirs(out, exist_ok=True)
    subprocess.run(["vasmm68k_mot", "-Fbin", "-m68040", "-no-opt", "-quiet", "-o", os.path.join(out, "t_dfpmis_pipe.bin"),
                    os.path.join(T, "cache_asm", "t_dfpmis_pipe.s")], check=True, stderr=subprocess.DEVNULL)
    subprocess.run(["python3", os.path.join(T, "bin2hex.py"), os.path.join(out, "t_dfpmis_pipe.bin"), os.path.join(out, "t_dfpmis_pipe.hex")], check=True)
    with ThreadPoolExecutor(j) as ex:
        for r in ex.map(lambda n: run(n, out), names):
            print(r, flush=True)

if __name__ == "__main__":
    main()
