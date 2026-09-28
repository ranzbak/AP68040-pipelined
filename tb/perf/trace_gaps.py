#!/usr/bin/env python3
"""trace_gaps.py <trace.txt> <image.bin> [base]: where the lost clocks are.
Each retired instruction's gap (clocks since the previous retirement) minus
one is its lost time.  Totals by cause, and the worst instructions with
their disassembly.  Cause of an instruction's lost clocks, first match:
  redirect  it is the first retirement after a redirect (the refill)
  slowread  it had a data read answered from the port
  fastread  it had a data read answered by the fast path
  other     none of those (multi-clock execution, ID/EA-calc stalls, ...)
"""
import sys, collections, capstone
tr, img = sys.argv[1], open(sys.argv[2], 'rb').read()
base = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_040)
def dis(pc):
    o = pc - base
    for i in md.disasm(img[o:o + 10], pc):
        return f"{i.mnemonic} {i.op_str}"
    return "?"
ev = [l.split() for l in open(tr)]
last_ret = None; pend_redir = None; reads = collections.defaultdict(set)
lost = collections.Counter(); cause_tot = collections.Counter(); n = 0
per_pc = collections.defaultdict(lambda: [0, 0, collections.Counter()])
redir_src = collections.Counter()
for e in ev:
    k, c = e[0], int(e[1])
    if k == 'D':
        pend_redir = e[2]; redir_src[e[2]] += 1
    elif k in 'FS':
        reads[int(e[2], 16)].add(k)
    elif k == 'R':
        pc = int(e[2], 16); n += 1
        if last_ret is not None:
            l = c - last_ret - 1
            if pend_redir: cause = 'redirect-' + pend_redir
            elif 'S' in reads[pc]: cause = 'slowread'
            elif 'F' in reads[pc]: cause = 'fastread'
            else: cause = 'other'
            cause_tot[cause] += l
            p = per_pc[pc]; p[0] += 1; p[1] += l; p[2][cause] += l
        last_ret = c; pend_redir = None; reads[pc] = set()
tot = sum(cause_tot.values())
print(f"{n} instructions, {tot} lost clocks ({tot / max(n,1):.2f} per instruction)")
for k, v in cause_tot.most_common(): print(f"  {k:12s} {v:6d}  {100.0 * v / max(tot,1):5.1f} %")
print("redirects by source:", dict(redir_src))
print("worst instructions (lost clocks, count, per-exec, cause split):")
for pc, (cnt, l, cs) in sorted(per_pc.items(), key=lambda x: -x[1][1])[:30]:
    print(f"  {pc:06x} {l:5d} x{cnt:<4d} {l / cnt:4.1f}  {dis(pc):32s} {dict(cs)}")
