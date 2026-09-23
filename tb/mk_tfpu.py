#!/usr/bin/env python3
"""mk_tfpu.py <t_fpu.s> [--diag] [--skip N] ... -> a variant on stdout

The reference's t_fpu.s stops at the first failing check, which makes a
section-by-section picture expensive to get.  This script produces variants
of it for the pipelined core's compat leg (plan M10.6):

  --diag     `hfail` reports the stacked format/vector word instead of the
             generic test number 98, so a handler failure names the vector
             whose frame was wrong.
  --diagpc   ... reports the LOW WORD of the stacked PC instead, which says
             WHICH instruction produced the frame the handler rejected.
  --skip N   drop the Nth `;-----` section (1-based, as `--list` prints
             them), so the run carries on past a known gap into the next
             one.  Sections are dropped as whole line ranges, which is only
             safe for sections that leave no state behind -- each skip is
             recorded in PLAN.md's M10.6 table with what it was hiding.
  --list     print the sections with their numbers and line ranges.
"""
import sys, re

def sections(lines):
    hdr = [(i, l) for i, l in enumerate(lines) if re.match(r'^;-{3,}', l)]
    out = []
    for k, (i, l) in enumerate(hdr):
        end = hdr[k + 1][0] if k + 1 < len(hdr) else len(lines)
        out.append((k + 1, i, end, l.strip().lstrip(';-').strip()))
    return out

def main():
    src = sys.argv[1]
    args = sys.argv[2:]
    lines = open(src).read().split("\n")
    secs = sections(lines)
    if "--list" in args:
        for n, a, b, name in secs:
            print(f"{n:3d}  lines {a+1:5d}-{b:5d}  {name}")
        return
    skip = {int(args[i + 1]) for i, a in enumerate(args) if a == "--skip"}
    drop = set()
    for n, a, b, name in secs:
        if n in skip:
            drop.update(range(a, b))
    out = [l for i, l in enumerate(lines) if i not in drop]
    if "--diagpc" in args:
        txt = "\n".join(out)
        txt = txt.replace("hfail:\n\tfailt\t98",
                          "hfail:\n\tmove.w\t4(sp),d7\n\tjmp\tfail_all")
        out = txt.split("\n")
    elif "--diag" in args:
        txt = "\n".join(out)
        txt = txt.replace("hfail:\n\tfailt\t98",
                          "hfail:\n\tmove.w\t6(sp),d7\n\tjmp\tfail_all")
        out = txt.split("\n")
    print("\n".join(out))

main()
