#!/bin/bash
# Misaligned-read path mutant table (findings/loadstore/plan.md step 3,
# AP040_DFP_MIS): see dfpmis_mutants.py (the table, the build and the runs).
#   bash tb/perf/dfpmis_mutants.sh [-j N] [-o out-dir] [mutant names...]
exec python3 "$(dirname "$0")/dfpmis_mutants.py" "$@"
