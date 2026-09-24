# Pipelined AP68040: timing pass, branch `pipe-timing` (from 3af610f)

This was an unattended overnight pass on 2026-09-24.  The goal was shorter clk_38 paths in the
FPU-on configuration (the routed `stage_ap040_pipe_fpu_vid` met clk_38 by only +0.010 ns, and
clk_114 -> clk_38 by +0.003 ns) without changing behaviour.

**One commit is a BUG FIX, not timing: cc65d93, the 2^31-word freeze.**  See its section below.

## How it was measured

- **OOC flow.** The flow is `ooc/` in the worktree; it is git-excluded and was not committed.
  `ooc_top.v` instantiates `ap040_pipe_tg68k_compat` exactly as `rtl/soc/TG68K.vhd` `g_pipe`
  does: HAS_MMU=1, HAS_FPU=1, ENABLE_CACHE=1, POST_STORES=1, FILL_CHANNEL=0, BUS16=0, the same
  constant ties and the same OPEN outputs, with debug_* left open.  It uses the Minimig tree's
  block-RAM `rtl/cpu040/dpram.v`.
- **Vivado steps.** `ooc_pr.tcl` runs synth, opt, place, phys_opt and route, all at default
  directives, with 4 threads.  clk_38 has a period of 26.446 ns.  Every input has an input delay
  of `period - 8.815 + 0.9` ns, which models the clk_114 acknowledge window.  Every output has an
  output delay of `period - 17.63` ns, the two-cycle multicycle.  The 0.9 ns external delay is a
  guess, so the input numbers are rough.
- **Advisory only (Q13).** The routed whole design is the judge.  This flow's run-to-run
  sensitivity is about 1 ns on a path that did not change.  For example, the MOVEM family moved
  from +1.566 to +0.508 between cc65d93 and 47f84d7, and 47f84d7 does not touch it.  Read single
  numbers with that in mind; the logic-level counts are the steadier signal.
- **Tests per commit.**
  - `tb/run_pipe_tests.sh` in full (205 legs, 206 from cc65d93).
  - The Kickstart differential bench (a copy in the session scratchpad, built from a `git archive`
    of each commit) in three legs: LC040, FPU, and board parameters with the FPU (MMU, caches,
    posted stores).  Each leg compares instructions, cycles and the md5 of the full retire trace
    against 3af610f.

## Results

**Kickstart legs, the same at 3af610f and after every commit**

| leg | instructions | cycles | trace md5 |
|---|---|---|---|
| LC040 | 2,288,738 | 26,758,312 | `226dee9c38ae207adbbaa9a15bda9ca9` |
| FPU | 2,289,114 | 26,762,177 | `0883f09d58d2ecac42ae3a7d1aa417d3` |
| board + FPU | 2,289,114 | 30,469,809 | `e1e1da00dc410921c1ed4a2f46522197` |

**OOC timing and tests per commit, at 26.446 ns unless noted**

| commit | reg-to-reg WNS | worst reg-to-reg path | m_ack -> fpc (input) | LUTs | suite |
|---|---|---|---|---|---|
| 3af610f (base) | **-0.290** | `eaf_o[dk]` -> EX result -> FMOVEM dyn popcount -> `eaf_o.u1_val` | +0.036 | 30,784 | 205/205 |
| 67706d2 | -0.243 | `eaf_o[dr]` -> EX flags -> fw_ccr -> TRAPcc -> eaf_stall -> `u_if/fpc` | -0.015 | 31,054 | 205/205 |
| 9025b70 | +0.190 | `eaf_o[dk]` -> ROX modulo -> Z -> fw_ccr -> ... -> `u_if/fpc` | -0.029 | 30,627 | 205/205 |
| 762a6fc | +0.671 | `u_if/issued` (32-bit count + compare) -> q_v0 -> ... -> `u_if/fpc` | -0.248 | 30,481 | 205/205 |
| cc65d93 | **+1.566** | `mm_mask` -> MOVEM register select -> `eaf_o.c` | -0.262 | 30,421 | 206/206 |
| 47f84d7 | +0.508 (noise, see above) | `mm_mask` -> `eaf_o.st_data` | -0.199 | 30,444 | 206/206 |
| 47f84d7 at 24.0 ns | +0.400 (about +2.8 at 26.446) | `mm_mask` -> `eaf_o.st_data` | -0.020 | 30,729 | |
| cc2c97e at 24.0 ns | +0.006 | `u_if/qcnt` -> room check -> `u_if/fpc` (the MOVEM family is gone) | -0.180 | 30,849 | 206/206 |
| **cc2c97e (tip)** | **+0.451** | `eaf_o[cls]` -> EX ALU -> Z -> fw_ccr -> trapn_ov / tr_go -> fin -> ID consume_nf -> `u_if/fpc` | -0.102 | 30,677 | 206/206 |
| 3af610f at 24.0 ns | **-1.944** | `eaf_o[cls]` -> ... -> `u_if/fpc` | -0.307 | 31,142 | |

**Summary, like for like:**

| constraint | 3af610f | cc2c97e | change |
|---|---|---|---|
| 26.446 ns | -0.290 ns, 30,784 LUTs | +0.451 ns, 30,677 LUTs | +0.74 ns, -107 LUTs |
| 24.0 ns | -1.944 ns, 31,142 LUTs | +0.006 ns, 30,849 LUTs | +1.95 ns, -293 LUTs |

- The goal was >= 1.0 ns at the real period.  It is met by the 24 ns run: +0.006 ns there is
  about +2.45 ns at 26.446.
- It is not met by the 26.446 run, at +0.451.  At the looser constraint the tool works less hard.
- Both runs sit inside this flow's roughly 1 ns spread.  The routed whole design decides.
- The acknowledge input paths did not move beyond noise.  The base run's +0.036 was the best
  sample, and the others range from -0.02 to -0.26.

## The commits

1. **67706d2: latch the dynamic FMOVEM list's byte count at P_FPU entry.**
   - Before: `fp_anv`, the An update, took 12 x popcount(op_c), and op_c can be EX's forwarded
     result.
   - Why latching is equivalent: an FP instruction serialises, and FMOVEM writes no Dn.  So the
     count at entry equals the count later.
2. **9025b70: apply TRAPcc's decision after stepf.**
   - Before: br_cc, from the CCR EX forwards in the same clock, was at the head of stepf's `fin`
     chain.  From there it reached eaf_stall, EA-calc's redirect, ID's consume and IF's fetch PC.
     This is the family the routed FPU build met by +0.010.
   - Now: stepf runs with trap_n = 0 and `trapn_ov` applies the trap arm afterwards.
   - Why it is equivalent: trap_n implies cls = TRAPCC, which rules out every earlier arm.
3. **762a6fc: ROXL/ROXR count modulo by a constant per size.**
   - Before: `n % (nbits+1)` with a variable divisor built a five-deep cascade of carry chains on
     EX's X/Z flags.
   - Checked with a differential bench of the old ALU against the new one over 1,280,000
     vectors: 0 differences.
4. **cc65d93: BUG FIX, the 2^31-word freeze** (also the next timing step).
   - The fault: IF compared a 32-bit count of the words it hands ID against PROG_WORDS, even in
     the wrapper, which passes 32'h7FFF_FFFF to mean "no bound".  After 2^31 - 1 words IF stops
     handing ID anything, for good.  Nothing faults, nothing halts, and no interrupt can be taken.
   - How long that takes: at the Kickstart bench's rate, about six minutes of 37.8 MHz execution.
     Time spent in STOP does not count.
   - Proof: `tb/tb_issued_wrap.v` presets the count to 32'h7FFF_FF00.  At 67706d2 it wedges
     (`issued=7fffffff q_v0=0`, phase timeout, fault=0 halted=0); it passes after the fix.  This
     is the new `compat:issued_wrap` leg.
   - Candidate for the "Frontier Elite II freezes after ~5 min" report.  Not proven on hardware.
5. **47f84d7: IF's room check uses ID's consume without the flush term.**
   - Why it is equivalent: flush_id is a subset of redirect_valid, and after_c and qpc ignore
     consume under a redirect.
   - It takes two logic levels off the acknowledge -> fetch-PC path.  The OOC gain is within
     noise, so drop this commit if the routed build doesn't like it.
6. **cc2c97e: MOVEM's next-register index is a register.**
   - What changed: mm_k_q is loaded with lsb16 of the value mm_mask is given, at every place
     mm_mask is written.  That takes the 16-bit priority encoder off mm_mask -> ra_c -> op_c ->
     st_data/c.
   - Checks:
     - A simulation-only invariant prints an ERROR whenever mm_k_q != lsb16(mm_mask).  It never
       fired in the 206 legs or the three Kickstart legs.
     - A mutant that drops one update fires it at once (the movem program).

## Tried and dropped

- **Keeping IF's fetch-PC adder ahead of can_issue** (`(* keep *) fpc_inc`).
  - OOC reg-to-reg fell from +1.566 to +0.137, and the input path did not improve.  Not
    committed.
  - It is related to ab95926's lesson: forcing the tool's structure costs more than it saves.

## What is left, and why it needs an architectural change

- **The acknowledge family (clk_114 -> clk_38).**
  - The chain: m_ack -> WB store hold -> ex_stall -> EA-fetch fin -> eaf_stall -> ea_stall /
    eac_redir_v -> ID consume -> IF room check -> f_req -> f_gnt -> can_issue -> fetch-PC adder.
    It is 20 levels deep, inside an 8.8 ns window.
  - What would fix it: Q12's early acknowledge from the wrapper, or Q9(b)'s skid register between
    EX and WB.  The skid register costs a clock per store, or a sequencing change.  Both are
    Paul's calls.
- **EX's flags into EA-fetch's `fin` (the tip's worst path).**
  - The route: EX's ALU computes Z from the final result mux, about 20 levels.  Then fw_ccr ->
    br_cc -> trapn_ov (1 gate) -> tr_go (it depends on exc_go) -> fin -> ID consume -> IF.
  - Pure-timing next steps:
    - Compute Z and N for add/sub/logic ops in parallel with the result mux, not after it.  This
      is an ALU restructure.
    - Take br_cc out of tr_go the same way trap_n came out of stepf.
  - A cycle-changing step (not taken): hold TRAPcc one clock when EX writes the CCR.  It is
    rare, but it changes cycles.
- **EX's result, forwarded into EA-fetch's operands** (`eaf_o` -> ALU -> `w0_val` -> fwd ->
  op_x -> `eaf_o`).  This is the classic one-cycle forward.  It now has slack, but it is the next
  structural limit after the MOVEM family.
