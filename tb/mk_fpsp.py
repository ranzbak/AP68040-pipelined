#!/usr/bin/env python3
"""mk_fpsp.py <out.s> <out.exp> -- the FPSP program (plan M10, 2026-09-24)

Writes tb/fpsp_asm/fpsp_lib.s and its .exp: Thomas Richter's 68040.library
(MMULib 40.2, relocated by mk_fpsplib.py) installs Motorola's M68040 FPSP
into the vector table with its OWN installer, then a user-mode program runs
the floating-point instructions a real 68040 does not implement and stores
every result.  Every expected value is computed HERE, with mpmath at 300
bits, never read back from the design:

  pass A (FPCR = 0: extended, round to nearest)   each transcendental is
      checked BIT-EXACTLY against fpsp_model.c -- an independent C
      transcription of the FPSP's algorithms (Previous's softfloat_fpsp.c),
      built from tb/fpsp_model/ -- and the generator refuses a model value
      more than MAXULP ulps from mpmath's exactly rounded one, and writes
      that distance into the .exp.  The FPSP's documented accuracy is "within
      1 ulp in 64 significant bit" (ssin.sa and the others); it is not met
      everywhere (sin(100) 2 ulp, cos(1000) 19: REDUCEX), which is the
      FPSP's, not the core's -- the model shows the same digits.  Results
      exact by definition (FINT, FMOD, FREM, FGETEXP, FGETMAN, FSCALE) are
      checked against mpmath exactly, FMOVECR against Motorola's own
      constant table (get_op.sa: e is $ADF85458_A2BB4A9A in round-to-
      nearest, one below the exactly rounded value, and so is the 68040's).
  pass B (FPCR = $80: double precision)            the same functions, the
      result stored as a double and checked EXACTLY against the correctly
      rounded double -- "i.e. within 0.5001 ulp to 53 bits if the result is
      subsequently rounded to double precision" (the same headers).  An
      argument whose true value lies within 2^-10 ulp of a double rounding
      midpoint is left out of pass B, because there the documented bound
      does not decide the rounding; the generator says which.

The FPSR condition-code byte is checked exactly for every case; the rest of
FPSR where the rule is simple (the quotient byte of FMOD/FREM, INEX2 of
FINT) is checked exactly too.
"""
import os
import subprocess
import sys
import mpmath
from mpmath import mpf

mpmath.mp.prec = 300
MAXULP = 32
HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.environ.get("FPSP_MODEL", os.path.join(HERE, "build", "fpsp_model"))

RES = 0x20000        # 16 bytes per pass-A case: 12 result + 4 FPSR
RESB = 0x24000       # 12 bytes per pass-B case: 8 result + 4 FPSR
OPND = 0x28000       # operand table, 12 bytes each
DIAG = 0x7000        # $7000 unexpected-vector word, $7004 its PC, $7008 Alert code, $700C cases done


# --------------------------------------------------------------- IEEE helpers
def split(x):
    """exact (sign, mantissa integer, exponent) with x = m * 2^e"""
    x = mpf(x)
    s = 1 if x < 0 else 0
    m, e = mpmath.mpf(abs(x)).man_exp
    return s, int(m), int(e)


def round_bits(x, bits):
    """RNE to `bits` significant bits: (sign, mantissa of exactly `bits` bits, e) with value m*2^e"""
    s, m, e = split(x)
    if m == 0:
        return s, 0, 0
    n = m.bit_length()
    sh = n - bits
    if sh > 0:
        q, r = divmod(m, 1 << sh)
        half = 1 << (sh - 1)
        if r > half or (r == half and (q & 1)):
            q += 1
        m, e = q, e + sh
        if m.bit_length() > bits:
            m >>= 1
            e += 1
    else:
        m, e = m << -sh, e + sh
    return s, m, e


def to_ext(x):
    s, m, e = round_bits(x, 64)
    if m == 0:
        return (s << 15), 0
    exp = e + 63 + 16383
    assert 0 < exp < 0x7FFF, "extended range"
    return (s << 15) | exp, m


def to_dbl(x):
    s, m, e = round_bits(x, 53)
    if m == 0:
        return s << 63
    exp = e + 52 + 1023
    assert 0 < exp < 0x7FF, "double range"
    return (s << 63) | (exp << 52) | (m & ((1 << 52) - 1))


def dbl_val(bits):
    s = bits >> 63
    exp = (bits >> 52) & 0x7FF
    frac = bits & ((1 << 52) - 1)
    v = mpf(frac | (1 << 52)) * mpf(2) ** (exp - 1075)
    return -v if s else v


def near_mid(x, bits):
    """True when x lies within 2^-10 ulp of a rounding midpoint at `bits`"""
    s, m, e = split(x)
    if m == 0:
        return False
    n = m.bit_length()
    sh = n - bits
    if sh <= 0:
        return False
    frac = mpf(m % (1 << sh)) / mpf(1 << sh)
    return abs(frac - mpf(0.5)) < mpf(2) ** -10


def ext_words(se, m):
    return [se << 16, (m >> 32) & 0xFFFFFFFF, m & 0xFFFFFFFF]


def cc_of(x):
    """FPSR condition codes N Z I NAN in bits 27..24"""
    if x == 0:
        return 0x04000000 | (0x08000000 if mpmath.sign(x) < 0 else 0)
    return 0x08000000 if x < 0 else 0


# --------------------------------------------------------------- the cases
def ftrunc(x):
    return mpmath.floor(x) if x >= 0 else mpmath.ceil(x)


def frne(x):
    f = mpmath.floor(x)
    d = x - f
    if d > 0.5 or (d == 0.5 and int(f) % 2 == 1):
        return f + 1
    return f


# (mnemonic, opmode, function, exact?)
MONADIC = {
    "fsin":    (0x0E, mpmath.sin, False),
    "fcos":    (0x1D, mpmath.cos, False),
    "ftan":    (0x0F, mpmath.tan, False),
    "fasin":   (0x0C, mpmath.asin, False),
    "facos":   (0x1C, mpmath.acos, False),
    "fatan":   (0x0A, mpmath.atan, False),
    "fsinh":   (0x02, mpmath.sinh, False),
    "fcosh":   (0x19, mpmath.cosh, False),
    "ftanh":   (0x09, mpmath.tanh, False),
    "fatanh":  (0x0D, mpmath.atanh, False),
    "fetox":   (0x10, mpmath.exp, False),
    "fetoxm1": (0x08, mpmath.expm1, False),
    "ftwotox": (0x11, lambda x: mpf(2) ** x, False),
    "ftentox": (0x12, lambda x: mpf(10) ** x, False),
    "flogn":   (0x14, mpmath.log, False),
    "flognp1": (0x06, mpmath.log1p, False),
    "flog10":  (0x15, mpmath.log10, False),
    "flog2":   (0x16, lambda x: mpmath.log(x, 2), False),
    "fgetexp": (0x1E, lambda x: mpf(split(x)[1].bit_length() - 1 + split(x)[2]), True),
    "fgetman": (0x1F, lambda x: abs(x) / mpf(2) ** (split(x)[1].bit_length() - 1 + split(x)[2]) * (1 if x > 0 else -1), True),
    "fint":    (0x01, frne, True),
    "fintrz":  (0x03, ftrunc, True),
}

# pass A: (mnemonic, argument as a decimal string; the operand is its nearest double)
PASS_A = [
    ("fsin", "0.5"), ("fsin", "1.0"), ("fsin", "-2.5"), ("fsin", "100.0"), ("fsin", "1e-5"),
    ("fcos", "0.5"), ("fcos", "2.0"), ("fcos", "1000.0"),
    ("ftan", "0.5"), ("ftan", "1.2"),
    ("fasin", "0.5"), ("facos", "0.3"), ("fatan", "2.0"), ("fatan", "-0.5"),
    ("fsinh", "1.5"), ("fcosh", "1.5"), ("ftanh", "0.8"), ("fatanh", "0.5"),
    ("fetox", "1.0"), ("fetox", "-3.5"), ("fetox", "10.0"),
    ("fetoxm1", "1e-3"), ("fetoxm1", "0.5"),
    ("ftwotox", "3.3"), ("ftentox", "2.5"),
    ("flogn", "2.0"), ("flogn", "10.0"), ("flogn", "0.3"),
    ("flognp1", "1e-4"), ("flognp1", "1.5"),
    ("flog10", "1000.0"), ("flog10", "7.0"), ("flog2", "8.0"), ("flog2", "3.0"),
    ("fgetexp", "1000.0"), ("fgetman", "1000.0"), ("fgetexp", "-0.1"), ("fgetman", "-0.1"),
    ("fint", "2.5"), ("fint", "-3.7"), ("fint", "3.5"), ("fintrz", "-3.7"), ("fintrz", "5.99"),
]
# pass B: the transcendentals again, rounded to double by the FPSP itself
PASS_B = [c for c in PASS_A if not MONADIC[c[0]][2]]

# dyadic: (mnemonic, opmode, dest, src) -> dest op src
DYADIC = [
    ("fmod", 0x21, "10.0", "3.0"), ("fmod", 0x21, "-7.5", "2.0"), ("fmod", 0x21, "100.25", "0.75"),
    ("frem", 0x25, "10.0", "3.0"), ("frem", 0x25, "11.0", "3.0"), ("frem", 0x25, "-7.5", "2.0"),
    ("fscale", 0x26, "1.5", "3.0"), ("fscale", 0x26, "-5.0", "-2.0"),
]

# FMOVECR: (rom offset, value)
# (rom offset, value, Motorola's round-to-nearest table entry, get_op.sa)
MOVECR = [(0x00, mpmath.pi, (0x4000, 0xC90FDAA22168C235)),
          (0x0B, mpmath.log10(2), (0x3FFD, 0x9A209A84FBCFF798)),
          (0x0C, mpmath.e, (0x4000, 0xADF85458A2BB4A9A)),
          (0x0D, 1 / mpmath.log(2), (0x3FFF, 0xB8AA3B295C17F0BC)),
          (0x0E, 1 / mpmath.log(10), (0x3FFD, 0xDE5BD8A937287195)),
          (0x0F, mpf(0), (0x0000, 0)),
          (0x30, mpmath.log(2), (0x3FFE, 0xB17217F7D1CF79AC)),
          (0x31, mpmath.log(10), (0x4000, 0x935D8DDDAAA8AC17)),
          (0x32, mpf(1), (0x3FFF, 0x8000000000000000)),
          (0x33, mpf(10), (0x4002, 0xA000000000000000)),
          (0x3A, mpf(10) ** 128, (0x41A8, 0x93BA47C980E98CE0)),
          (0x3B, mpf(10) ** 256, (0x4351, 0xAA7EEBFB9DF9DE8E))]


def imm(op, fmt, dst, v, nw, note):
    """an FP instruction with an immediate source, as raw words (vasm would
    convert an integer written for .d/.s to its VALUE, not its bit pattern)"""
    ws = [0xF23C, 0x4000 | (fmt << 10) | (dst << 7) | op]
    ws += [(v >> (16 * (nw - 1 - i))) & 0xFFFF for i in range(nw)]
    return "\tdc.w\t" + ",".join("$%04X" % w for w in ws) + "\t; " + note


def dbl(s):
    return dbl_val(to_dbl(mpf(s)))


class Model:
    """batch queries to fpsp_model (the C transcription of the FPSP)"""

    def __init__(self):
        self.q = []

    def ask(self, op, x, prec=80):
        self.q.append((op, x, prec))
        return len(self.q) - 1

    def run(self):
        if not os.path.exists(MODEL):
            raise SystemExit("mk_fpsp: build %s first (see tb/fpsp_model/fpsp_model.c)" % MODEL)
        lines = []
        for op, x, prec in self.q:
            se, m = to_ext(x)
            lines.append("prec %x 0" % prec)
            lines.append("%s %x %x" % (op, se, m))
        r = subprocess.run([MODEL], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True)
        self.a = [tuple(int(v, 16) for v in l.split()) for l in r.stdout.split("\n") if l.strip()]
        assert len(self.a) == len(self.q), r.stdout


PACKOUT = 0x2C000     # packed-decimal stores, 12 bytes each


def packed(sm, exp, integer, frac):
    """the 96-bit packed-decimal image: mantissa sign, decimal exponent,
    the integer digit and up to 16 fraction digits (M68000PM 1.6.6)"""
    se = 1 if exp < 0 else 0
    e = "%03d" % abs(exp)
    w = (sm << 95) | (se << 94)
    for i, c in enumerate(e):
        w |= int(c) << (88 - 4 * i)
    w |= int(integer) << 64
    frac = (frac + "0" * 16)[:16]
    for i, c in enumerate(frac):
        w |= int(c) << (60 - 4 * i)
    return w


def ext_val(se, m):
    if se & 0x7FFF == 0 and m == 0:
        return mpf(0)
    # Motorola's extended format reads exponent field 0 as -16383 (the integer
    # bit is explicit), not x87's -16382 -- and so does the FPSP (nrm_set)
    v = mpf(m) * mpf(2) ** ((se & 0x7FFF) - 16383 - 63)
    return -v if se & 0x8000 else v


def ulp_dist(a, b):
    """distance in extended ulps between two (se, mant) images of one sign"""
    ka = ((a[0] & 0x7FFF) << 63) | (a[1] & ((1 << 63) - 1))
    kb = ((b[0] & 0x7FFF) << 63) | (b[1] & ((1 << 63) - 1))
    return abs(ka - kb) if (a[0] ^ b[0]) & 0x8000 == 0 else 1 << 80


def main():
    out_s, out_e = sys.argv[1:3]
    S = []
    E = []
    opnd = []          # 12-byte extended operand images
    model = Model()
    notes = []

    def opnd_of(v):
        se, m = to_ext(v)
        opnd.append((se, m))
        return OPND + 12 * (len(opnd) - 1)

    def emit(x):
        S.append(x)

    emit("""; fpsp_lib.s -- GENERATED by tb/mk_fpsp.py; edit that, not this.
;
; Motorola's M68040 FPSP, exactly as Thomas Richter's 68040.library 40.2
; (MMULib) carries it, installed by the library's own code, runs the
; floating-point instructions a 68040 does not implement.  mk_fpsplib.py
; relocates the library to $10000 (code) / $1A000 (data); this program
; builds a minimal ExecBase (Supervisor, Alert, CacheClearU, AttnFlags) and
; a library base, calls the library's installer at code+$520, checks the
; vectors it wrote, drops to USER mode and runs the cases.  Expected values:
; mk_fpsp.py (mpmath at 300 bits, the FPSP model, Motorola's tables).
;
; diff: --cycles 4000000
v_flin	equ	unexp
v_ill	equ	unexp
v_adr	equ	unexp
v_alin	equ	unexp
v_prv	equ	unexp
v_fmt	equ	unexp
v_trp0	equ	unexp
	include	"../pipe_asm/vectors.inc"
	include	"../build/fpsp040lib.inc"

EXECBASE equ	$1C400
LIBBASE	equ	$1B000
SSP_TOP	equ	$3F000
USP_TOP	equ	$3E000

	org	$400
start:
	bra.w	main
halt:
	bra.s	halt			; $404: the bench stops when this retires
main:
	lea	SSP_TOP,sp
	lea	EXECBASE,a0
	move.w	#$4EF9,-$1E(a0)		; Supervisor()
	move.l	#x_super,-$1C(a0)
	move.w	#$4EF9,-$6C(a0)		; Alert()
	move.l	#x_alert,-$6A(a0)
	move.w	#$4EF9,-$27C(a0)	; CacheClearU()
	move.l	#x_rts,-$27A(a0)
	move.b	#$4F,$129(a0)		; AttnFlags: 010/020/030/040 + FPU40, no 68881/2
	lea	LIBBASE,a6
	move.l	a0,$30(a6)		; lib_SysBase
	clr.b	$22(a6)			; FPUControl flags: every FPSP path on
	move.l	a0,LIB_SYSBASE		; the handlers' SysBase (code+$330 does this)
	jsr	LIB_INSTALL		; the library's own FPSP installer
	lea	EXECBASE,a0		; (the installer used a0 for the VBR)
	move.b	$129(a0),$%x		; AttnFlags afterwards: 68881/2 now claimed
	move.l	$2C,$%x			; vector 11
	move.l	$DC,$%x			; vector 55
	move.l	$C4,$%x			; vector 49
	lea	USP_TOP,a0
	move.l	a0,usp
	move.w	#$0000,sr		; USER mode from here on
""" % (DIAG + 0x10, DIAG + 0x14, DIAG + 0x18, DIAG + 0x1C))
    E.append("halt 00000404")
    E.append("# the installer ran: AttnFlags gained AFF_68881|AFF_68882, and the")
    E.append("# vectors are the library's handlers (fpsp_fline, fpsp_unsupp, inex)")
    E.append("m8 %08x 0000007f" % (DIAG + 0x10))
    E.append("m32 %08x %08x" % (DIAG + 0x14, 0x107C4))
    E.append("m32 %08x %08x" % (DIAG + 0x18, 0x115C4))
    E.append("m32 %08x %08x" % (DIAG + 0x1C, 0x10690))
    E.append("# nothing unexpected: no stray vector, no Alert() from the FPSP")
    E.append("m32 %08x 00000000" % DIAG)
    E.append("m32 %08x 00000000" % (DIAG + 8))

    n = 0          # result slots used
    ncount = 0     # cases the program counts
    packout = []

    def ncount_add():
        nonlocal ncount
        ncount += 1
    pending = []   # (slot, label, exact value or None, model query or table value, fpsr mask, fpsr)

    def case_a(label, reg, val, how, fpsr_mask, fpsr_want):
        """store FPSR first (a store is an FP instruction and clears INEX2),
        then the result"""
        nonlocal n, ncount
        a = RES + 16 * n
        emit("\tfmove.l\tfpsr,$%x" % (a + 12))
        emit("\tfmove.x\tfp%d,$%x" % (reg, a))
        emit("\taddq.l\t#1,$%x" % (DIAG + 12))
        pending.append((n, label, val, how, fpsr_mask, fpsr_want))
        n += 1
        ncount += 1

    def extra_slot(label, reg, val, how):
        nonlocal n
        emit("\tfmove.x\tfp%d,$%x" % (reg, RES + 16 * n))
        pending.append((n, label, val, how, 0, 0))
        n += 1

    emit("\n;----------------------------------------------------------- pass A")
    emit("\tfmove.l\t#0,fpcr")
    for k, (mn, arg) in enumerate(PASS_A):
        op, fn, exact = MONADIC[mn]
        x = dbl(arg)
        y = fn(x)
        oa = opnd_of(x)
        emit("\tfmove.l\t#0,fpsr")
        # vary the source form: register, extended memory, double immediate
        form = k % 3
        if form == 0:
            emit("\tfmove.x\t$%x,fp0" % oa)
            emit("\t%s.x\tfp0,fp1\t\t; %s(%s)" % (mn, mn, arg))
        elif form == 1:
            emit("\t%s.x\t$%x,fp1\t\t; %s(%s), extended memory source" % (mn, oa, mn, arg))
        else:
            emit(imm(op, 5, 1, to_dbl(x), 4, "%s(%s), double immediate" % (mn, arg)))
        want = cc_of(y)
        if mn in ("fint", "fintrz"):
            want |= 0x0208 if y != x else 0     # INEX2, AINEX
            case_a("%s(%s)" % (mn, arg), 1, y, "exact", 0xFFFFFFFF, want)
        elif exact:
            case_a("%s(%s)" % (mn, arg), 1, y, "exact", 0xFF000000, want)
        else:
            case_a("%s(%s)" % (mn, arg), 1, y, model.ask(mn, x), 0xFF000000, want)

    emit("\n; FSINCOS: cos to FPc, sin to FPs")
    x = dbl("0.7")
    oa = opnd_of(x)
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.x\t$%x,fp0" % oa)
    emit("\tfsincos.x\tfp0,fp2:fp1")
    case_a("fsincos(0.7) sin", 1, mpmath.sin(x), model.ask("fsin", x), 0xFF000000, 0)
    extra_slot("fsincos(0.7) cos", 2, mpmath.cos(x), model.ask("fcos", x))

    emit("\n; the dyadic ones: dest op src")
    for mn, op, d, s in DYADIC:
        xd, xs = dbl(d), dbl(s)
        od, os_ = opnd_of(xd), opnd_of(xs)
        emit("\tfmove.l\t#0,fpsr")
        emit("\tfmove.x\t$%x,fp1" % od)
        emit("\tfmove.x\t$%x,fp0" % os_)
        emit("\t%s.x\tfp0,fp1\t\t; %s(%s, %s)" % (mn, mn, d, s))
        if mn == "fscale":
            y = xd * mpf(2) ** int(ftrunc(xs))
            want = cc_of(y)
        else:
            qq = xd / xs
            q = ftrunc(qq) if mn == "fmod" else frne(qq)
            y = xd - xs * q
            qb = (0x80 if qq < 0 else 0) | (int(abs(q)) & 0x7F)
            want = cc_of(y) | (qb << 16)
            if y == 0:
                want = (want & ~0x08000000) | (0x08000000 if xd < 0 else 0)
        case_a("%s(%s, %s)" % (mn, d, s), 1, y, "exact", 0xFFFFFFFF, want)

    emit("\n; FMOVECR: the constant ROM (the 68040 traps every offset to the FPSP)")
    for off, v, tab in MOVECR:
        emit("\tfmove.l\t#0,fpsr")
        emit("\tfmovecr.x\t#$%02x,fp1" % off)
        case_a("fmovecr #$%02x" % off, 1, v, tab, 0xFF000000, cc_of(v))

    emit("\n; (An)+ and -(An): the 68040 has already stepped An when the FPSP runs")
    x = dbl("0.25")
    oa = opnd_of(x)
    emit("\tmovea.l\t#$%x,a2" % oa)
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfetox.x\t(a2)+,fp1")
    emit("\tmove.l\ta2,$%x" % (DIAG + 0x20))
    case_a("fetox (a2)+", 1, mpmath.exp(x), model.ask("fetox", x), 0xFF000000, 0)
    E.append("m32 %08x %08x" % (DIAG + 0x20, oa + 12))
    x = dbl("0.75")
    oa = opnd_of(x)
    emit("\tmovea.l\t#$%x,a3" % (oa + 12))
    emit("\tfmove.l\t#0,fpsr")
    emit("\tflogn.x\t-(a3),fp1")
    emit("\tmove.l\ta3,$%x" % (DIAG + 0x24))
    case_a("flogn -(a3)", 1, mpmath.log(x), model.ask("flogn", x), 0xFF000000, cc_of(mpmath.log(x)))
    E.append("m32 %08x %08x" % (DIAG + 0x24, oa))

    emit("\n; integer, single and word sources, converted by the hardware before the trap")
    emit("\tfmove.l\t#0,fpsr")
    emit(imm(0x15, 0, 1, 100000, 2, "flog10.l #100000,fp1"))
    case_a("flog10.l #100000", 1, mpf(5), model.ask("flog10", mpf(100000)), 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit(imm(0x10, 1, 1, 0x3F000000, 2, "fetox.s #0.5,fp1"))
    case_a("fetox.s #0.5", 1, mpmath.exp(mpf(0.5)), model.ask("fetox", mpf(0.5)), 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit(imm(0x11, 4, 1, 0xFFFD, 1, "ftwotox.w #-3,fp1"))
    case_a("ftwotox.w #-3", 1, mpf(1) / 8, model.ask("ftwotox", mpf(-3)), 0xFF000000, 0)

    emit("\n;----------------------------------------------------------- pass U")
    emit("; unsupported data types (vector 55): packed decimal, denormals")
    # packed decimal in: immediate and memory
    for lab, val, dec in (("fmove.p #1.25E+2", mpf(125), (0, 2, "1", "25")),
                          ("fmove.p #-3.75E-1", mpf(-0.375), (1, -1, "3", "75")),
                          ("fmove.p #1.5E+10", mpf(15) * 10 ** 9, (0, 10, "1", "5"))):
        w = packed(*dec)
        emit("\tfmove.l\t#0,fpsr")
        emit("\tdc.w\t$F23C,$4C80," + ",".join("$%04X" % ((w >> (16 * (5 - i))) & 0xFFFF) for i in range(6))
             + "\t; " + lab + ",fp1")
        case_a(lab, 1, val, "exact", 0xFF000000, cc_of(val))
    oa = OPND + 12 * len(opnd)
    opnd.append(("P", packed(0, 0, "3", "1415926535897932")))
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.p\t$%x,fp1\t\t; 3.1415926535897932E+0 from memory" % oa)
    v = mpf("3.1415926535897932")
    case_a("fmove.p 3.1415926535897932E+0", 1, v, "ulp1", 0xFF000000, 0)
    # packed decimal out, static k-factor
    for lab, val, k, dec in (("fmove.p 125.0{#3}", mpf(125), 3, (0, 2, "1", "25")),
                             ("fmove.p -0.375{#2}", mpf(-0.375), 2, (1, -1, "3", "8")),
                             ("fmove.p 1.0{#1}", mpf(1), 1, (0, 0, "1", ""))):
        oa = opnd_of(val)
        dst = PACKOUT + 12 * len(packout)
        packout.append((lab, packed(*dec)))
        emit("\tfmove.x\t$%x,fp1" % oa)
        emit("\tfmove.l\t#0,fpsr")
        emit("\tfmove.p\tfp1,$%x{#%d}\t; %s" % (dst, k, lab))
        emit("\taddq.l\t#1,$%x" % (DIAG + 12))
        ncount_add()
    # denormals
    den = (0x0000, 0x0000000000000100)            # extended denormal 2^-16438 (Motorola)
    oa = OPND + 12 * len(opnd)
    opnd.append(den)
    dval = ext_val(*den) * 1
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.x\t$%x,fp1\t\t; an extended denormal into a register" % oa)
    case_a("fmove.x denormal (2^-16438)", 1, None, den, 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.x\t$%x,fp1" % oa)
    emit(imm(0x23, 2, 1, (0x406B << 80) | (1 << 63), 6, "fmul.x #2^108,fp1 -- a denormal register operand"))
    case_a("denormal * 2^108", 1, mpf(2) ** -16330, "exact", 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.x\t$%x,fp1" % opnd_of(mpf(2) ** 1000))
    emit(imm(0x23, 5, 1, 1, 4, "fmul.d #2^-1074,fp1 -- a double denormal source"))
    case_a("2^1000 * double denormal 2^-1074", 1, mpf(2) ** -74, "exact", 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit(imm(0x00, 1, 1, 0x00400000, 2, "fmove.s #2^-127,fp1 -- a single denormal source"))
    case_a("fmove.s single denormal 2^-127", 1, mpf(2) ** -127, "exact", 0xFF000000, 0)
    emit("\tfmove.l\t#0,fpsr")
    emit("\tfmove.x\t$%x,fp1" % (OPND + 12 * opnd.index(den)))
    emit(imm(0x22, 2, 1, 0, 6, "fadd.x #0,fp1 -- denormal + 0"))
    case_a("denormal + 0", 1, None, den, 0xFF000000, 0)

    nA = n
    nb = 0
    emit("\n;----------------------------------------------------------- pass B")
    emit("\tfmove.l\t#$80,fpcr\t\t; round to double, nearest")
    skipped = []
    passb = []
    for k, (mn, arg) in enumerate(PASS_B):
        op, fn, exact = MONADIC[mn]
        x = dbl(arg)
        y = fn(x)
        if near_mid(y, 53):
            skipped.append("%s(%s)" % (mn, arg))
            continue
        a = RESB + 12 * nb
        emit("\tfmove.l\t#0,fpsr")
        emit(imm(op, 5, 1, to_dbl(x), 4, "%s(%s)" % (mn, arg)))
        emit("\tfmove.l\tfpsr,$%x" % (a + 8))
        emit("\tfmove.d\tfp1,$%x" % a)
        emit("\taddq.l\t#1,$%x" % (DIAG + 12))
        passb.append((nb, mn, arg, y, model.ask(mn, x, 64)))
        nb += 1
        ncount += 1
    emit("\tfmove.l\t#0,fpcr")

    model.run()
    worst = []
    for slot, label, val, how, fmask, fwant in pending:
        a = RES + 16 * slot
        E.append("# A%d %s" % (slot, label))
        if how == "exact":
            se, m = to_ext(val)
            E.append("x80 %08x %04x %016x 0" % (a, se, m))
        elif how == "ulp1":
            se, m = to_ext(val)
            E.append("#   within 1 ulp of the exactly rounded value")
            E.append("x80 %08x %04x %016x 1" % (a, se, m))
        elif isinstance(how, tuple) and val is None:
            se, m = how
            E.append("#   the operand's own image")
            E.append("x80 %08x %04x %016x 0" % (a, se, m))
        elif isinstance(how, tuple):
            se, m = how
            d = ulp_dist(how, to_ext(val))
            E.append("#   Motorola's table entry (%d ulp from the exactly rounded value)" % d)
            E.append("x80 %08x %04x %016x 0" % (a, se, m))
        else:
            se, m = model.a[how]
            d = ulp_dist((se, m), to_ext(val))
            if d > MAXULP:
                raise SystemExit("mk_fpsp: the model's %s is %d ulp from mpmath" % (label, d))
            worst.append((d, label))
            E.append("#   the FPSP model's value, %d ulp from the exactly rounded one" % d)
            E.append("x80 %08x %04x %016x 0" % (a, se, m))
        if fmask == 0xFFFFFFFF:
            E.append("m32 %08x %08x" % (a + 12, fwant))
        elif fmask:
            E.append("m8 %08x %08x" % (a + 12, (fwant >> 24) & 0xFF))
    for i, (lab, w) in enumerate(packout):
        E.append("# P%d %s" % (i, lab))
        for j in range(3):
            E.append("m32 %08x %08x" % (PACKOUT + 12 * i + 4 * j, (w >> (64 - 32 * j)) & 0xFFFFFFFF))
    for slot, mn, arg, y, q in passb:
        a = RESB + 12 * slot
        d = to_dbl(y)
        se, m = model.a[q]
        md = to_dbl(ext_val(se, m))
        E.append("# B%d %s(%s), exactly rounded to double%s" % (slot, mn, arg,
                 "" if md == d else " (the FPSP model differs here: %016x)" % md))
        E.append("m32 %08x %08x" % (a, d >> 32))
        E.append("m32 %08x %08x" % (a + 4, d & 0xFFFFFFFF))
        E.append("m8 %08x %08x" % (a + 8, cc_of(y) >> 24))
    if skipped:
        E.append("# left out of pass B (true value within 2^-10 ulp of a double midpoint): " + ", ".join(skipped))

    E.append("# every case ran")
    E.append("m32 %08x %08x" % (DIAG + 12, ncount))
    emit("""
	move.l	#$600D,$%x
	bra.w	halt

; exec.library Supervisor(): the routine at a5 ends in RTE
x_super:
	move.w	#0,-(sp)		; format $0
	pea	x_rts(pc)
	move.w	sr,-(sp)
	jmp	(a5)
x_rts:
	rts

; exec.library Alert(): the FPSP met a frame it cannot handle
x_alert:
	move.l	d7,$%x
	bra.w	halt

unexp:
	move.w	6(sp),$%x		; format/vector of the stray exception
	move.l	2(sp),$%x		; and its PC
	bra.w	halt
""" % (DIAG + 0x28, DIAG + 8, DIAG + 2, DIAG + 4))
    E.append("m32 %08x 0000600d" % (DIAG + 0x28))
    emit("\n\torg\t$%x" % OPND)
    for se, m in opnd:
        if se == "P":
            emit("\tdc.l\t$%08x,$%08x,$%08x" % ((m >> 64) & 0xFFFFFFFF, (m >> 32) & 0xFFFFFFFF, m & 0xFFFFFFFF))
        else:
            emit("\tdc.l\t$%08x,$%08x,$%08x" % tuple(ext_words(se, m)))
    emit("\n\torg\tLIB_CODE")
    emit("\tincbin\t\"../build/fpsp040lib.bin\"")
    open(out_s, "w").write("\n".join(S) + "\n")
    open(out_e, "w").write("\n".join(E) + "\n")
    worst.sort(reverse=True)
    print("mk_fpsp: pass A %d slots, pass B %d (%d left out near a midpoint); FPSP model vs mpmath, worst: %s"
          % (nA, nb, len(skipped), ", ".join("%s %d ulp" % (l, d) for d, l in worst[:4])))


if __name__ == "__main__":
    main()
