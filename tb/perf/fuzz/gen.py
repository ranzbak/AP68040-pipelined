#!/usr/bin/env python3
"""gen.py <seed> <out.s> [nops]: a random load/store program for the compat
bench's differential runs (fuzz.sh).  Pointer registers a0-a3 stay around
the work area $2000-$2FFF at any alignment (the 68040 allows misaligned
data); the program mixes plain moves, read-modify-writes, store-then-load
pairs, misaligned copy loops, MOVEM and calls.  At the end it copies the
work area to $3000 and the registers to $3C00 (the bench dumps $3000-$3FFF)
and reports $600D."""
import random, sys

seed = int(sys.argv[1]); out = sys.argv[2]
nops = int(sys.argv[3]) if len(sys.argv) > 3 else 300
R = random.Random(seed)
L = []
def e(s): L.append("\t" + s)

SZ = ["b", "w", "l"]
def dreg(): return f"d{R.randrange(0, 7)}"      # d7 is the loop counter
def areg(): return f"a{R.randrange(0, 4)}"
def ea():
    a = areg()
    k = R.randrange(5)
    if k == 0: return f"({a})"
    if k == 1: return f"({a})+"
    if k == 2: return f"-({a})"
    return f"{R.randrange(-40, 41)}({a})"
def rebase(a):
    e(f"lea\t${R.randrange(0x2200, 0x2c00):x},{a}")

sub_n = 0
subs = []
user = [False]
def body(n, depth):
    global sub_n
    for _ in range(n):
        k = R.randrange(100)
        s = R.choice(SZ)
        if k < 22:   e(f"move.{s}\t{dreg()},{ea()}")
        elif k < 40: e(f"move.{s}\t{ea()},{dreg()}")
        elif k < 48: e(f"move.{s}\t{ea()},{ea()}")
        elif k < 56:
            op = R.choice(["add", "sub", "and", "or", "eor"])
            e(f"{op}.{s}\t{dreg()},{ea()}")
        elif k < 60: e(f"{R.choice(['addq', 'subq'])}.{s}\t#{R.randrange(1, 9)},{ea()}")
        elif k < 63: e(f"{R.choice(['clr', 'not', 'neg'])}.{s}\t{ea()}")
        elif k < 70:
            # a store and a load of the same or a nearby address
            a = areg(); d = R.randrange(-8, 9); d2 = d + R.randrange(-3, 4)
            e(f"move.{s}\t{dreg()},{d}({a})")
            for _ in range(R.randrange(0, 3)): e("addq.l\t#1,d6")
            e(f"move.{R.choice(SZ)}\t{d2}({a}),{dreg()}")
        elif k < 74:
            # a short copy loop, any alignment
            src, dst = R.sample(["a0", "a1", "a2", "a3"], 2)
            cnt = R.randrange(1, 12)
            e(f"moveq\t#{cnt - 1},d7")
            lbl = f"cp{len(L)}"
            L.append(f"{lbl}:\tmove.{s}\t({src})+,({dst})+")
            e(f"dbra\td7,{lbl}")
            rebase(src); rebase(dst)
        elif k < 78:
            regs = "d0-d3" if R.randrange(2) else "d2-d5"
            a = areg()
            if R.randrange(2): e(f"movem.l\t{regs},-({a})")
            else: e(f"movem.l\t({a})+,{regs}")
            rebase(a)
        elif k < 81 and depth == 0:
            # an exception: the handler reads its own frame.  Often right
            # behind a synchronous store (the I/O counter), so the exception's
            # last micro-op waits in EX while WB holds it (the SR hazard)
            if R.randrange(2): e(f"move.w\t{dreg()},$f1f4")
            e(f"trap\t#{R.randrange(0, 3)}")
        elif k < 82 and depth == 0 and not user[0]:
            # a stretch in user mode, left with TRAP #15
            user[0] = True
            e("andi.w\t#$dfff,sr")
        elif k < 83 and depth == 0 and user[0]:
            user[0] = False
            e("trap\t#15")
        elif k < 84 and depth == 0:
            sub_n += 1
            subs.append((f"sub{sub_n}", R.randrange(3, 12)))
            e(f"bsr\tsub{sub_n}")
        elif k < 90: e(f"{R.choice(['add', 'sub', 'eor', 'and'])}.l\t{dreg()},{dreg()}")
        elif k < 92:
            e(f"move.w\t{dreg()},$f1f4")      # the bench counts these writes
        elif k < 94:
            e(f"move.l\t{dreg()},-(sp)")
            e(f"move.l\t(sp)+,{dreg()}")
        else: rebase(areg())

L.append("\torg\t0\n\tdc.l\t$7000\n\tdc.l\tstart\n\trept\t30\n\tdc.l\tunexp\n\tendr\n"
         "\tdc.l\ttrp0,trp1,trp2\n\trept\t12\n\tdc.l\tunexp\n\tendr\n\tdc.l\ttrp15\n"
         "\trept\t208\n\tdc.l\tunexp\n\tendr\n\torg\t$400")
L.append("start:")
e("move.l\t#$80008000,d0"); e("movec\td0,cacr"); e("cpusha\tbc")
e("clr.w\t$f1f6")                          # the write counter
if seed & 1:
    # translation on, 4K pages, identity over the first 64K (as 68040.library
    # runs), tables at $5000
    e("lea\t$5000,a0"); e("move.l\t#$5200|3,(a0)")
    e("lea\t$5200,a0"); e("move.l\t#$5400|3,(a0)")
    e("lea\t$5400,a0"); e("moveq\t#0,d0"); e("moveq\t#15,d1")
    L.append("pt:\tmove.l\td0,d2"); e("or.l\t#1,d2"); e("move.l\td2,(a0)+"); e("add.l\t#$1000,d0"); e("dbra\td1,pt")
    e("move.l\t#$5000,d0"); e("movec\td0,srp"); e("movec\td0,urp"); e("pflusha")
    e("move.l\t#$8000,d0"); e("movec\td0,tc")
e("lea\t$2000,a0"); e("move.w\t#$3ff,d7"); e(f"move.l\t#${R.getrandbits(32):08x},d0")
L.append("init:\tmove.l\td0,(a0)+"); e("rol.l\t#5,d0"); e("add.l\t#$9e3779b9,d0"); e("dbra\td7,init")
for i in range(7): e(f"move.l\t#${R.getrandbits(32):08x},d{i}")
for i in range(4): rebase(f"a{i}")
e("lea\t$6c00,a4"); e("move.l\ta4,usp")
body(nops, 0)
if user[0]: e("trap\t#15")
# the results: the work area and the registers
e("lea\t$2000,a4"); e("lea\t$3000,a5"); e("move.w\t#$2ff,d7")
L.append("cpy:\tmove.l\t(a4)+,(a5)+"); e("dbra\td7,cpy")
e("movem.l\td0-d6/a0-a3,$3c00")
e("moveq\t#0,d0"); e("movec\td0,tc"); e("move.l\t#$00008000,d0"); e("movec\td0,cacr")
e("move.w\t$f1f6,$3c40")                   # I/O writes counted (DE off: from memory)
e("move.w\t#$600d,$f102")
L.append("halt:\tbra.s\thalt")
L.append("unexp:\tmove.w\t#99,$f100\n\tmove.w\t#$bad0,$f102\n.u:\tbra.s\t.u")
# the handlers: read the frame (SR and PC), a few operations, return
for t in range(3):
    L.append(f"trp{t}:")
    e(f"move.w\t(sp),{dreg()}")
    e(f"move.l\t2(sp),{dreg()}")
    e(f"move.w\t6(sp),{dreg()}")
    body(R.randrange(2, 6), 1)
    e("rte")
L.append("trp15:\tori.w\t#$2000,(sp)\n\trte")
for name, n in subs:
    L.append(f"{name}:")
    body(n, 1)
    e("rts")
open(out, "w").write("\n".join(L) + "\n")
