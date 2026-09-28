#!/bin/sh
# build.sh [out.bin] [NRUNS]: xSysInfo's Dhrystone for the compat perf bench,
# compiled with xSysInfo's flags (Makefile: -O2 -m68000 -mtune=68020-60,
# functions and loops aligned to 16) by m68k-linux-gnu-gcc in docker
# (image m68kgcc: ubuntu:24.04 + gcc-m68k-linux-gnu).
set -e
cd "$(dirname "$0")"
OUT=${1:-dhry.bin}; N=${2:-20}
docker run --rm -u $(id -u):$(id -g) -v "$PWD":/w -w /w m68kgcc:latest sh -c "
F='-O2 -m68000 -mtune=68020-60 -msoft-float -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns -nostdinc -Ishim -I.'
m68k-linux-gnu-gcc \$F -falign-functions=16 -falign-loops=16 -c -o dhry_1.o dhry_1.c
m68k-linux-gnu-gcc \$F -falign-functions=16 -falign-loops=16 -c -o dhry_2.o dhry_2.c
m68k-linux-gnu-gcc \$F -DNRUNS=$N -c -o dhry_harness.o dhry_harness.c
m68k-linux-gnu-gcc -m68000 -c -o crt0.o crt0.S
m68k-linux-gnu-gcc -m68000 -nostdlib -static -T dhry.ld -o dhry.elf crt0.o dhry_harness.o dhry_1.o dhry_2.o -lgcc
m68k-linux-gnu-objcopy -O binary dhry.elf $OUT
m68k-linux-gnu-objdump -d dhry.elf > dhry.lst
# the SoC bench's variant: linked at \$41000000, entered at soc_main (first)
m68k-linux-gnu-gcc \$F -DNO_MAIN -c -o dhry_lib.o dhry_harness.c
m68k-linux-gnu-gcc \$F -DNRUNS=${SOCN:-10} -ffunction-sections -c -o dhry_soc.o dhry_soc.c
m68k-linux-gnu-gcc -m68000 -nostdlib -static -T dhry_soc.ld -o dhry_soc.elf dhry_soc.o dhry_lib.o dhry_1.o dhry_2.o -lgcc
m68k-linux-gnu-objcopy -O binary dhry_soc.elf dhry_soc.bin
rm -f *.o"
