/* dhry_harness.c - xSysInfo's Dhrystone (dhry_1.c, dhry_2.c, from
 * github.com/reinauer/xSysInfo 922a716, BSD-2-Clause; Dhrystone 2.1 by
 * R. P. Weicker) on tb_ap040_pipe_compat.v with tb_perf_compat.v: the
 * library routines Dhrystone calls, then a warm-up and NRUNS measured runs
 * inside the perf window ($F1F0 nonzero opens it, zero closes it); $600D
 * at $F102 ends the program.  Built by build.sh with xSysInfo's flags. */
#include "dhry.h"
extern int  Dhry_Initialize(void);
extern void Dhry_Run(unsigned long);
#ifndef NRUNS
#define NRUNS 20
#endif
static char heap[512];
static unsigned long hp;
void *malloc(unsigned long n) { void *p = &heap[hp]; hp += (n + 3) & ~3UL; return p; }
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) ; return r; }
int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (unsigned char)*a - (unsigned char)*b;
}
void *memset(void *d, int c, unsigned long n)
{
	char *dd = d;
	while (n--) *dd++ = (char)c;
	return d;
}
void *memcpy(void *d, const void *s, unsigned long n)
{
	char *dd = d; const char *ss = s;
	while (n--) *dd++ = *ss++;
	return d;
}
#ifndef NO_MAIN
#define REG16(a) (*(volatile unsigned short *)(a))
extern void cache_on(void);
int main(void)
{
	cache_on();
	Dhry_Initialize();
	Dhry_Run(2);                  /* warm-up: caches */
	REG16(0xF1F0) = 1;
	Dhry_Run(NRUNS);
	REG16(0xF1F0) = 0;
	REG16(0xF102) = 0x600D;
	for (;;) ;
}
#endif
