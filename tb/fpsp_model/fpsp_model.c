/* fpsp_model.c -- an INDEPENDENT model of the M68040 FPSP's arithmetic, for
 * tb/mk_fpsp.py (plan M10, the FPSP task of 2026-09-24).
 *
 * Andreas Grabher's softfloat_fpsp.c (written for the Previous NeXT emulator,
 * "The functions are derived from FPSP library") is a C transcription of
 * Motorola's FPSP algorithms -- the same REDUCEX loop, the same tables, the
 * same extended-precision operation order.  It is used here as the bit-exact
 * oracle for what the FPSP computes: tb/fpsp_asm/fpsp_lib.s runs the REAL
 * FPSP (68040.library 40.2) on the pipelined core, and every result must be
 * identical to this model's.  mpmath then says how close the FPSP itself is
 * to the true value (it is not always within its documented 1 ulp: sin(100)
 * is 2 ulp off, cos(1000) 19 -- the core and this model agree on both).
 *
 * Build (softfloat from the pistorm tree, which carries the C version):
 *   P=/home/paul/work/amiga/hardware/pistorm
 *   gcc -O1 -w -I$P -I$P/softfloat -o fpsp_model fpsp_model.c \
 *       $P/softfloat/softfloat.c $P/softfloat/softfloat_fpsp.c -lm
 *
 * stdin: "<op> <se> <mant>" lines (hex), "prec <50|40|20> 0" (hex: 80, 64 or
 * 32 bits) to set the
 * rounding precision; stdout: "<se> <mant>" per operation.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "softfloat/softfloat.h"
/* reads: <op> <se> <mant> [<se2> <mant2>] ; prints se mant */
int main(void) {
  char op[32]; unsigned se, se2; unsigned long long m, m2;
  float_status st; memset(&st, 0, sizeof st);
  st.float_rounding_mode = float_round_nearest_even; st.floatx80_rounding_precision = 80;
  while (scanf("%31s %x %llx", op, &se, &m) == 3) {
    floatx80 a; a.high = se; a.low = m; floatx80 r;
    uint64_t q = 0; flag s = 0;
    if (!strcmp(op, "prec")) { st.floatx80_rounding_precision = se; continue; }
    if (!strcmp(op,"fsin")) r = floatx80_sin(a,&st);
    else if (!strcmp(op,"fcos")) r = floatx80_cos(a,&st);
    else if (!strcmp(op,"ftan")) r = floatx80_tan(a,&st);
    else if (!strcmp(op,"fasin")) r = floatx80_asin(a,&st);
    else if (!strcmp(op,"facos")) r = floatx80_acos(a,&st);
    else if (!strcmp(op,"fatan")) r = floatx80_atan(a,&st);
    else if (!strcmp(op,"fsinh")) r = floatx80_sinh(a,&st);
    else if (!strcmp(op,"fcosh")) r = floatx80_cosh(a,&st);
    else if (!strcmp(op,"ftanh")) r = floatx80_tanh(a,&st);
    else if (!strcmp(op,"fatanh")) r = floatx80_atanh(a,&st);
    else if (!strcmp(op,"fetox")) r = floatx80_etox(a,&st);
    else if (!strcmp(op,"fetoxm1")) r = floatx80_etoxm1(a,&st);
    else if (!strcmp(op,"ftwotox")) r = floatx80_twotox(a,&st);
    else if (!strcmp(op,"ftentox")) r = floatx80_tentox(a,&st);
    else if (!strcmp(op,"flogn")) r = floatx80_logn(a,&st);
    else if (!strcmp(op,"flognp1")) r = floatx80_lognp1(a,&st);
    else if (!strcmp(op,"flog10")) r = floatx80_log10(a,&st);
    else if (!strcmp(op,"flog2")) r = floatx80_log2(a,&st);
    else if (!strcmp(op,"fgetexp")) r = floatx80_getexp(a,&st);
    else if (!strcmp(op,"fgetman")) r = floatx80_getman(a,&st);
    else if (!strcmp(op,"fint")) r = floatx80_round_to_int(a,&st);
    else if (!strcmp(op,"fintrz")) r = floatx80_round_to_int_toward_zero(a,&st);
    else { printf("? %s\n", op); continue; }
    printf("%04x %016llx\n", (unsigned)r.high, (unsigned long long)r.low);
  }
  return 0;
}
flag floatx80_is_nan( floatx80 a )
{
    return ( ( a.high & 0x7FFF ) == 0x7FFF ) && (int64_t) ( a.low<<1 );
}
