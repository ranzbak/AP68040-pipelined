/* dhry_soc.c - the Dhrystone of dhry_harness.c for the SoC bench
 * (sim/ddr3_cpu, findings/ap040-pipelined/tests/perf/run_ddr3_dhry.sh):
 * linked to run from DDR3 fast RAM at $41000000 (dhry_soc.ld), entered by
 * dhry_ddr3.asm; the measured window is the SoC probe's mailbox phase 2
 * ($1010).  The library routines are dhry_harness.c's (-DNO_MAIN). */
extern int  Dhry_Initialize(void);
extern void Dhry_Run(unsigned long);
#ifndef NRUNS
#define NRUNS 10
#endif
#define MBOX_PHASE (*(volatile unsigned long *)0x1010)
void soc_main(void)
{
	Dhry_Initialize();
	Dhry_Run(2);                  /* warm-up */
	MBOX_PHASE = 1;
	MBOX_PHASE = 2;               /* the measured window */
	Dhry_Run(NRUNS);
	MBOX_PHASE = 3;
}
